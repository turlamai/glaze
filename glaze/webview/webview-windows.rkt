#lang racket/base

;; Windows WebView backend — pure Racket FFI, no compiler.
;;
;; STATUS (Phase 3): full pipeline — window, WebView2 environment,
;; controller, Navigate, post-open navigate/title/url, and window capture —
;; all against vtable indices verified against the official WebView2 SDK
;; header (Microsoft.Web.WebView2 nupkg, build/native/include/webview2.h).
;;
;; Vtable indices (IUnknown = 0..2):
;;   ICoreWebView2Environment : CreateCoreWebView2Controller = 3
;;   ICoreWebView2Controller  : get_CoreWebView2 = 25
;;   ICoreWebView2            : get_Source = 4, Navigate = 5,
;;                              get_DocumentTitle = 48, OpenDevToolsWindow = 51
;;
;; HISTORY / debugging note: for a long time this backend appeared blocked
;; on a "COM apartment / object lifetime" issue — the ICoreWebView2 obtained
;; from get_CoreWebView2 crashed on ANY vtable access, even AddRef. The real
;; cause was a wrong vtable index: calling slot 3 on the controller invokes
;; get_IsVisible, which writes a BOOL into the out-pointer; reading that
;; back as ICoreWebView2* yields 1 + heap garbage — a non-null pointer to
;; nothing. If you extend this file, verify every new vtable slot against
;; the SDK header, not against "neighboring" interfaces.
;;
;; Object lifetime: the controller and CoreWebView2 interfaces are AddRef'd
;; inside the controller callback and kept in the handle, so Navigate /
;; title / url work after the init callbacks complete. All calls stay on
;; the single Racket OS thread (the STA the environment was created on).
;;
;; FFI findings (verified, reusable):
;;   - COM vtable methods are read with _fpointer and called via
;;     (cast fn _fpointer (_fun ...)). Using _pointer instead returns garbage.
;;   - out parameters ([out] T**) use the two-arrow form:
;;       (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))
;;   - ALWAYS check the HRESULT before using the out value.
;;   - The async init chain must run inside the callbacks (each callback
;;     advances the next step); our PeekMessage pump on the same thread
;;     delivers them.
;;
;; Requires the WebView2Loader.dll matching the process architecture, shipped
;; under glaze/native/win-x64/ or win-arm64/. The WebView2 Evergreen Runtime
;; is preinstalled on Windows 11.

(require ffi/unsafe
         racket/async-channel
         racket/list
         racket/path
         racket/string
         racket/system
         racket/runtime-path
         "../native-transport.rkt"
         "../tray/tray-protocol.rkt"
         "../private/id-allocator.rkt"
         "../private/win-stdio.rkt"
         "../private/win32-arch.rkt"
         "../private/windows-capture.rkt")

(provide open-webview
         supported?
         close
         navigate
         title
         url
         capture!
         set-title!
         set-size!
         set-fullscreen!
         geometry
         set-geometry!
         screen-area
         focus!
         set-menu!
         closed?
         win:webview?
         win:webview-hwnd)

(define-runtime-path here ".")
(define loader-path (build-path here ".." "native" (webview2-loader-subdir) "WebView2Loader"))

(define user32 (ffi-lib "user32"))
(define kernel32 (ffi-lib "kernel32"))
(define ole32 (ffi-lib "ole32"))

;; Opt in to system-controlled non-client dark mode. Windows 11 documents
;; attribute 20 as following the system setting, not forcing a dark caption.
;; Older systems may reject the attribute; leave their default frame intact.
(define dwmapi
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (ffi-lib "dwmapi")))
(define DwmSetWindowAttribute
  (and dwmapi
       (get-ffi-obj "DwmSetWindowAttribute"
                    dwmapi
                    (_fun _pointer _uint32 _pointer _uint32 -> _int32)
                    (lambda () #f))))
(define DWMWA_USE_IMMERSIVE_DARK_MODE 20)

(define (apply-system-titlebar-theme! hwnd)
  (when (and hwnd DwmSetWindowAttribute)
    (define enabled (malloc _int32 'atomic))
    (ptr-set! enabled _int32 1)
    (DwmSetWindowAttribute hwnd DWMWA_USE_IMMERSIVE_DARK_MODE enabled (ctype-sizeof _int32)))
  (void))
(define loader
  (or (with-handlers ([exn:fail? (lambda (e) #f)])
        (ffi-lib loader-path))
      ;; Packaged apps: raco distribute extracts runtime-path files into a
      ;; flat exts tree, so loader-path's ".." hop out of it never exists
      ;; there. Fall back to the bare loader name, which LoadLibrary resolves
      ;; against the executable's directory — build-app stages the DLL there.
      (with-handlers ([exn:fail? (lambda (e) #f)])
        (ffi-lib "WebView2Loader"))))

(define S_OK 0)
;; HRESULT is signed: the unsigned literal does not fit the _int32
;; callback return type (QI for an unsupported IID would crash).
(define E_NOINTERFACE (- #x80004002 #x100000000))
;; Teardown abort: the runtime delivers this through the controller callback
;; when in-flight controller work is aborted by parent-window destruction.
(define E_ABORT (- #x80004004 #x100000000))
(define IID-IUnknown (bytes 0 0 0 0 0 0 0 0 #xC0 0 0 0 0 0 0 #x46))
;; ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler
(define IID-EnvHandler
  (bytes #x89 #x33 #x8A #x4E #xC9 #xD8 #x42 #x32 #x9C #x0E #x9C #xCB #x5B #x9F #x79 #xF5))
;; ICoreWebView2CreateCoreWebView2ControllerCompletedHandler
(define IID-CtrlHandler
  (bytes #xE0 #xA7 #xC1 #x63 #x68 #xCB #x3B #x44 #x8B #xA8 #x4D #x08 #xCF #x11 #xF0 #xAE))
;; ICoreWebView2EnvironmentOptions (WebView2.h 1.0.2903.40:
;; IID = 2fde08a8-1e9a-4766-8c05-95a9ceb9d1c5)
(define IID-EnvOptions
  (bytes #xA8 #x08 #xDE #x2F #x9A #x1E #x66 #x47 #x8C #x05 #x95 #xA9 #xCE #xB9 #xD1 #xC5))
;; ICoreWebView2WebMessageReceivedEventHandler
(define IID-WebMessageHandler
  (bytes #x19 #x3F #x21 #x57 #xE6 #x00 #xFA #x49 #x8E #x07 #x89 #x8E #xA0 #x1E #xCB #xD2))
;; ICoreWebView2WebResourceRequestedEventHandler
(define IID-WebResourceHandler
  (bytes #x4C #xB7 #x00 #xAB #xF1 #x15 #x46 #x46 #x80 #xE8 #xE7 #x63 #x41 #xD2 #x5D #x71))

;; Error-path diagnostics: unconditional, rare, and the only thing a terminal
;; run or a log sink sees by default.
(define (log fmt . args)
  (apply fprintf (current-error-port) (string-append "[glaze-win-webview] " fmt "\n") args))

;; Hot-path chatter (one line per resource request and per bridge message).
;; Opt-in with GLAZE_DEBUG=1 (the switch is defined in private/win-stdio):
;; printed unconditionally it was the first stdio write of every packaged
;; app, which on Windows made the Racket runtime open a console window and
;; then flood it (glaze#173).
(define (trace fmt . args)
  (when debug-trace-enabled?
    (apply fprintf (current-error-port) (string-append "[glaze-win-webview] " fmt "\n") args)))

;; UTF-16 helper (Racket has no string->bytes/utf-16).
(define conv (bytes-open-converter "platform-UTF-8" "platform-UTF-16"))
(define (wstr s)
  (define-values (out _in _status) (bytes-convert conv (string->bytes/utf-8 s)))
  (define n (bytes-length out))
  (define p (malloc _uint8 (+ n 2) 'raw))
  (memcpy p out n)
  (ptr-set! p _uint16 (quotient n 2) 0)
  p)

;; NOTE: bytes-open-converter is one-directional; converting UTF-16 back
;; with a UTF-8->UTF-16 converter silently produces garbage ("E\0\0\0...").
;; Walk the UTF-16 units directly instead.
(define (wstr->string p)
  (and p
       (let loop ([i 0]
                  [chars '()])
         (define u (ptr-ref p _uint16 i))
         (if (zero? u)
             (list->string (reverse chars))
             (loop (add1 i) (cons (integer->char u) chars))))))

(define (ptr->bytes p n)
  (define bs (make-bytes n))
  (memcpy bs p n)
  bs)

;; Read vtable[index] as a callable function pointer.
(define (vtfn obj index)
  (define vtable (ptr-ref obj _pointer))
  (ptr-ref (ptr-add vtable (* index (ctype-sizeof _pointer))) _fpointer))

;; ---- COM handler objects (hand-built vtable; function pointers kept alive) ----
(define handler-table (make-hasheq))
(define (make-com-handler iid on-invoke)
  (define (qi self in-iid out)
    (define incoming (ptr->bytes in-iid 16))
    (cond
      [(or (bytes=? incoming iid) (bytes=? incoming IID-IUnknown))
       (ptr-set! out _pointer 0 self)
       S_OK]
      [else
       (ptr-set! out _pointer 0 #f)
       E_NOINTERFACE]))
  (define (addref self)
    2)
  (define (release self)
    1)
  (define (invoke self errcode result)
    (on-invoke errcode result)
    S_OK)
  (define fn-qi (function-ptr qi (_fun _pointer _pointer _pointer -> _int32)))
  (define fn-add (function-ptr addref (_fun _pointer -> _uint32)))
  (define fn-rel (function-ptr release (_fun _pointer -> _uint32)))
  (define fn-inv (function-ptr invoke (_fun _pointer _int32 _pointer -> _int32)))
  (define vt (malloc (* 4 (ctype-sizeof _pointer)) _pointer 'raw))
  (ptr-set! vt _pointer 0 fn-qi)
  (ptr-set! vt _pointer 1 fn-add)
  (ptr-set! vt _pointer 2 fn-rel)
  (ptr-set! vt _pointer 3 fn-inv)
  (define obj (malloc (ctype-sizeof _pointer) _pointer 'raw))
  (ptr-set! obj _pointer 0 vt)
  (hash-set! handler-table obj (list fn-qi fn-add fn-rel fn-inv))
  obj)

;; Event handlers have a different Invoke signature than the init
;; callbacks: Invoke(self, sender, args) with TWO pointers. The init
;; handler's _int32 second-argument annotation would truncate a 64-bit
;; pointer, so event handlers get their own constructor.
(define (make-com-event-handler iid on-event)
  (define (qi self in-iid out)
    (define incoming (ptr->bytes in-iid 16))
    (cond
      ;; WebView2 queries the handler (at least for IUnknown) when the
      ;; listener is registered; answering S_OK without writing the out
      ;; pointer hands it a garbage pointer.
      [(or (bytes=? incoming iid) (bytes=? incoming IID-IUnknown))
       (ptr-set! out _pointer 0 self)
       S_OK]
      [else
       (ptr-set! out _pointer 0 #f)
       E_NOINTERFACE]))
  (define (addref self)
    2)
  (define (release self)
    1)
  (define (invoke self sender args)
    (on-event sender args)
    S_OK)
  (define fn-qi (function-ptr qi (_fun _pointer _pointer _pointer -> _int32)))
  (define fn-add (function-ptr addref (_fun _pointer -> _uint32)))
  (define fn-rel (function-ptr release (_fun _pointer -> _uint32)))
  (define fn-inv (function-ptr invoke (_fun _pointer _pointer _pointer -> _int32)))
  (define vt (malloc (* 4 (ctype-sizeof _pointer)) _pointer 'raw))
  (ptr-set! vt _pointer 0 fn-qi)
  (ptr-set! vt _pointer 1 fn-add)
  (ptr-set! vt _pointer 2 fn-rel)
  (ptr-set! vt _pointer 3 fn-inv)
  (define obj (malloc (ctype-sizeof _pointer) _pointer 'raw))
  (ptr-set! obj _pointer 0 vt)
  (hash-set! handler-table obj (list fn-qi fn-add fn-rel fn-inv))
  obj)

;; ---- Environment options object (hand-built COM, glaze#143) ----
;; The bundled WebView2Loader.dll does not export
;; CreateCoreWebView2EnvironmentOptions, so the options interface is
;; implemented here with the same hand-built-vtable technique as the
;; handlers above. Vtable order verified against WebView2.h 1.0.2903.40:
;;   IUnknown 0..2, get/put_AdditionalBrowserArguments 3/4,
;;   get/put_Language 5/6, get/put_TargetCompatibleBrowserVersion 7/8,
;;   get/put_AllowSingleSignOnUsingOSPrimaryAccount 9/10.
;; Propget strings are COM-owned: the caller frees them with
;; CoTaskMemFree, so they must come from CoTaskMemAlloc (ole32, bound above).
(define CoTaskMemAlloc (get-ffi-obj "CoTaskMemAlloc" ole32 (_fun _size -> _pointer)))
(define (com-wstr s)
  ;; CoTaskMemAlloc'd null-terminated UTF-16 copy of s.
  (define-values (out _in _status) (bytes-convert conv (string->bytes/utf-8 s)))
  (define n (bytes-length out))
  (define p (CoTaskMemAlloc (+ n 2)))
  (memcpy p out n)
  (ptr-set! p _uint16 (quotient n 2) 0)
  p)
(define (make-environment-options browser-args)
  (define args-box (box browser-args))
  (define (qi self in-iid out)
    (define incoming (ptr->bytes in-iid 16))
    (cond
      [(or (bytes=? incoming IID-EnvOptions) (bytes=? incoming IID-IUnknown))
       (ptr-set! out _pointer 0 self)
       S_OK]
      [else
       (ptr-set! out _pointer 0 #f)
       E_NOINTERFACE]))
  (define (addref self)
    2)
  (define (release self)
    1)
  (define (get-args self out)
    (ptr-set! out _pointer 0 (com-wstr (unbox args-box)))
    S_OK)
  (define (put-args self value)
    (set-box! args-box (wstr->string value))
    S_OK)
  (define (get-null self out)
    ;; Language: null means "use the browser default".
    (ptr-set! out _pointer 0 #f)
    S_OK)
  (define (get-ver self out)
    ;; TargetCompatibleBrowserVersion must name an installed runtime:
    ;; null/empty fails environment validation with E_INVALIDARG and an
    ;; uninstalled version with E_FILENOTFOUND (empirical, WebView2
    ;; runtime 157). Report the available evergreen runtime version.
    (define-values (hr vp)
      (if GetAvailableCoreWebView2BrowserVersionString
          (GetAvailableCoreWebView2BrowserVersionString #f)
          (values -1 #f)))
    (unless (and (zero? hr) vp)
      (error 'make-environment-options "no available WebView2 runtime version"))
    (ptr-set! out _pointer 0 (com-wstr (wstr->string vp)))
    S_OK)
  (define (put-ignore self value)
    S_OK)
  (define (get-false self out)
    (ptr-set! out _int32 0 0)
    S_OK)
  (define (put-ignore-bool self value)
    S_OK)
  (define fn-qi (function-ptr qi (_fun _pointer _pointer _pointer -> _int32)))
  (define fn-add (function-ptr addref (_fun _pointer -> _uint32)))
  (define fn-rel (function-ptr release (_fun _pointer -> _uint32)))
  (define fn-ga (function-ptr get-args (_fun _pointer _pointer -> _int32)))
  (define fn-pa (function-ptr put-args (_fun _pointer _pointer -> _int32)))
  (define fn-gn (function-ptr get-null (_fun _pointer _pointer -> _int32)))
  (define fn-gv (function-ptr get-ver (_fun _pointer _pointer -> _int32)))
  (define fn-pi (function-ptr put-ignore (_fun _pointer _pointer -> _int32)))
  (define fn-gf (function-ptr get-false (_fun _pointer _pointer -> _int32)))
  (define fn-pb (function-ptr put-ignore-bool (_fun _pointer _int32 -> _int32)))
  (define vt (malloc (* 11 (ctype-sizeof _pointer)) _pointer 'raw))
  (for ([i 11]
        [fn (list fn-qi fn-add fn-rel fn-ga fn-pa fn-gn fn-pi fn-gv fn-pi fn-gf fn-pb)])
    (ptr-set! vt _pointer i fn))
  (define obj (malloc (ctype-sizeof _pointer) _pointer 'raw))
  (ptr-set! obj _pointer 0 vt)
  ;; Keep the function pointers alive for the process lifetime: the
  ;; environment may read the options after the creation call returns.
  (hash-set! handler-table obj (list fn-qi fn-add fn-rel fn-ga fn-pa fn-gn fn-pi fn-gv fn-gf fn-pb))
  obj)
;; Acceptance-only escape hatch (glaze#143): synthetic-click media playback
;; for real-window acceptance harnesses. Default off; shipped apps must
;; never set it (it weakens the autoplay gesture gate process-wide).
(define (allow-programmatic-playback?)
  (equal? (getenv "GLAZE_ALLOW_PROGRAMMATIC_PLAYBACK") "1"))

;; Memory IStream for CreateWebResourceResponse (shcore, Windows 8+).
(define shcore
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (ffi-lib "shcore")))
(define SHCreateMemStream
  (and shcore
       (get-ffi-obj "SHCreateMemStream" shcore (_fun _pointer _uint -> _pointer) (lambda () #f))))

;; ---- Win32 / WebView2 bindings ----
(define CreateCoreWebView2EnvironmentWithOptions
  (and loader
       (get-ffi-obj "CreateCoreWebView2EnvironmentWithOptions"
                    loader
                    (_fun _pointer _pointer _pointer _pointer -> _int32)
                    (lambda () #f))))
(define GetAvailableCoreWebView2BrowserVersionString
  (and loader
       (get-ffi-obj "GetAvailableCoreWebView2BrowserVersionString"
                    loader
                    (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))
                    (lambda () #f))))
(define RegisterClassExW
  (get-ffi-obj "RegisterClassExW" user32 (_fun _pointer -> _ushort) (lambda () #f)))
;; Window icon. `raco exe --ico` stores the application icon as the module's
;; icon group named "APPLICATION" (the name GRacket.exe's own icon has). A
;; window class registered without icons gets the generic blank icon in the
;; title bar and Alt-Tab even though the executable carries the right one.
(define LoadImageW
  (get-ffi-obj "LoadImageW"
               user32
               (_fun _pointer _pointer _uint _int _int _uint -> _pointer)
               (lambda () #f)))
(define IMAGE_ICON 1)
(define LR_DEFAULTSIZE #x40)
(define LR_SHARED #x8000)
(define SM_CXSMICON 49)
(define SM_CYSMICON 50)
(define app-icon-group (wstr "APPLICATION"))

;; Loads an icon from the executable's resources: the "APPLICATION" group
;; first, then the first integer-identified group. #f when neither exists or
;; the FFI entry is unavailable; the caller then registers a class without an
;; icon, which is the pre-fix behavior.
(define (load-app-icon module cx cy flags)
  (and LoadImageW
       module
       (or (LoadImageW module app-icon-group IMAGE_ICON cx cy flags)
           (LoadImageW module (cast 1 _intptr _pointer) IMAGE_ICON cx cy flags))))
(define CreateWindowExW
  (get-ffi-obj "CreateWindowExW"
               user32
               (_fun _uint
                     _pointer
                     _pointer
                     _uint
                     _int
                     _int
                     _int
                     _int
                     _intptr
                     _pointer
                     _pointer
                     _pointer
                     ->
                     _pointer)
               (lambda () #f)))
(define DefWindowProcW
  (get-ffi-obj "DefWindowProcW"
               user32
               (_fun _pointer _uint _uintptr _intptr -> _intptr)
               (lambda () #f)))
(define ShowWindow (get-ffi-obj "ShowWindow" user32 (_fun _pointer _int -> _bool) (lambda () #f)))
(define PeekMessageW
  (get-ffi-obj "PeekMessageW"
               user32
               (_fun _pointer _pointer _uint _uint _uint -> _bool)
               (lambda () #f)))
(define TranslateMessage
  (get-ffi-obj "TranslateMessage" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define DispatchMessageW
  (get-ffi-obj "DispatchMessageW" user32 (_fun _pointer -> _intptr) (lambda () #f)))
(define PostMessageW
  (get-ffi-obj "PostMessageW" user32 (_fun _pointer _uint _uintptr _intptr -> _bool) (lambda () #f)))
(define GetModuleHandleW
  (get-ffi-obj "GetModuleHandleW" kernel32 (_fun _pointer -> _pointer) (lambda () #f)))
(define CoInitialize (get-ffi-obj "CoInitialize" ole32 (_fun _pointer -> _int32) (lambda () #f)))
(define GetClientRect
  (get-ffi-obj "GetClientRect" user32 (_fun _pointer _pointer -> _bool) (lambda () #f)))

(define-cstruct _WNDCLASSEXW
                ([cbSize _uint] [style _uint]
                                [lpfnWndProc _pointer]
                                [cbClsExtra _int]
                                [cbWndExtra _int]
                                [hInstance _pointer]
                                [hIcon _pointer]
                                [hCursor _pointer]
                                [hbrBackground _pointer]
                                [lpszMenuName _pointer]
                                [lpszClassName _pointer]
                                [hIconSm _pointer]))
(define-cstruct _MSG
                ([hwnd _pointer] [message _uint]
                                 [wParam _uintptr]
                                 [lParam _intptr]
                                 [time _uint]
                                 [pt _int]
                                 [pt2 _int]))
(define-cstruct _POINT ([x _long] [y _long]))
(define-cstruct _RECT ([left _long] [top _long] [right _long] [bottom _long]))
(define-cstruct _WINDOWPLACEMENT
                ([length _uint] [flags _uint]
                                [showCmd _uint]
                                [ptMinPosition _POINT]
                                [ptMaxPosition _POINT]
                                [rcNormalPosition _RECT]
                                [rcDevice _RECT]))
(define WM_DESTROY 2)
(define WM_CLOSE 16)
(define WM_SIZE 5)
(define WM_SETTINGCHANGE #x001A)
(define WM_THEMECHANGED #x031A)
(define WM_QUIT 18)
(define WM_COMMAND 273)
(define WS_OVERLAPPEDWINDOW #x00CF0000)
(define CW_USEDEFAULT -2147483648)
(define SW_SHOW 5)
(define PM_REMOVE 1)
;; RegisterClassExW/CreateWindowExW read this as UTF-16; a byte string would
;; register the ASCII bytes as UTF-16 code units (a mojibake name that
;; FindWindow and every inspection tool cannot match).
(define class-name (wstr "GlazeWebView"))

;; The HWND of the host window: #f until init creates it and after close.
;; Backend surface (Windows only), for checks that inspect the native window.
(define (win:webview-hwnd wv)
  (unbox (win:webview-hwnd-box wv)))

(struct win:webview
        (hwnd-box [controller-box #:mutable]
                  [cwv-box #:mutable]
                  [url #:mutable]
                  ready?-box
                  error-box
                  closed?-box
                  [thread #:mutable]
                  [deliver-queue #:mutable]
                  on-close)
  #:transparent)

;; WebView2 locks its user-data folder and keeps the lock briefly after
;; close. A fixed path, or even one folder per process, made a second window
;; in the same test (or a concurrent process) abort CreateController with
;; E_ABORT. Each open gets its own folder; GLAZE_WEBVIEW2_DATA_DIR still
;; selects a stable path for products that want a shared cache.
(define webview2-data-counter (box 0))
(define (new-webview2-data-folder)
  (or (let ([configured (getenv "GLAZE_WEBVIEW2_DATA_DIR")])
        (and configured (string->path configured)))
      (let ()
        (set-box! webview2-data-counter (add1 (unbox webview2-data-counter)))
        (build-path (find-system-path 'temp-dir)
                    (format "glaze-webview2-~a-~a-~a"
                            (current-seconds)
                            (unbox webview2-data-counter)
                            (random 1000000))))))

(define (supported?)
  (and (eq? (system-type 'os) 'windows) loader CreateCoreWebView2EnvironmentWithOptions #t))

;; WM_CLOSE from the title bar: forward to our close semantics.
(define wndprocs (make-hasheq)) ; hwnd-addr -> wv (for WM_CLOSE dispatch)
(define (resize-controller! wv hwnd)
  ;; Keep the WebView glued to the client area on window resizes.
  (define controller (win:webview-controller-box wv))
  (when controller
    (define rc (make-RECT 0 0 0 0))
    (GetClientRect hwnd rc)
    (define put-bounds (cast (vtfn controller 6) _fpointer (_fun _pointer _RECT -> _int32)))
    (put-bounds controller (make-RECT 0 0 (RECT-right rc) (RECT-bottom rc)))))

(define wndproc-cptr
  (function-ptr (lambda (hwnd msg w l)
                  (cond
                    [(= msg WM_SIZE)
                     (define wv (hash-ref wndprocs (cast hwnd _pointer _uintptr) #f))
                     (when wv
                       (resize-controller! wv hwnd))
                     0]
                    [(or (= msg WM_SETTINGCHANGE) (= msg WM_THEMECHANGED))
                     (when (hash-ref wndprocs (cast hwnd _pointer _uintptr) #f)
                       (apply-system-titlebar-theme! hwnd))
                     (DefWindowProcW hwnd msg w l)]
                    [(= msg WM_COMMAND)
                     ;; Menu bar selection: LOWORD(wParam) is the menu id.
                     (define id (bitwise-and w #xFFFF))
                     (define thunk (menu-action-lookup id))
                     (when thunk
                       (thunk))
                     0]
                    [(= msg WM_CLOSE)
                     (define wv (hash-ref wndprocs (cast hwnd _pointer _uintptr) #f))
                     (cond
                       [(and wv (not (unbox (win:webview-closed?-box wv))))
                        (set-box! (win:webview-closed?-box wv) #t)
                        ((win:webview-on-close wv))
                        (teardown-controller! wv)
                        (DestroyWindow-maybe hwnd)]
                       [else (DefWindowProcW hwnd msg w l)])]
                    [(= msg WM_DESTROY) 0]
                    [else (DefWindowProcW hwnd msg w l)]))
                (_fun _pointer _uint _uintptr _intptr -> _intptr)))

;; WM_CLOSE path needs DestroyWindow.
(define DestroyWindow (get-ffi-obj "DestroyWindow" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define (DestroyWindow-maybe hwnd)
  (when DestroyWindow
    (DestroyWindow hwnd))
  0)

;; Controller teardown shared by `close` and the WM_CLOSE path (glaze#146):
;; Close the controller BEFORE destroying its parent HWND, then pump briefly
;; so teardown callbacks land while the window is marked closed. Destroying
;; the window first aborts in-flight controller work and the runtime delivers
;; E_ABORT through the creation callback mid-teardown (hosted-runner flake).
;; ICoreWebView2Controller::Close = vtable slot 24 (WebView2.h 1.0.2903.40:
;; IUnknown 0..2, IsVisible 3/4, Bounds 5/6, ZoomFactor 7/8, ZoomChanged 9/10,
;; SetBoundsAndZoomFactor 11, MoveFocus 12, MoveFocusRequested 13/14,
;; GotFocus 15/16, LostFocus 17/18, AcceleratorKeyPressed 19/20,
;; ParentWindow 21/22, NotifyParentWindowPositionChanged 23, Close 24).
(define (teardown-controller! wv)
  (define controller (win:webview-controller-box wv))
  (when controller
    (define close-ctrl (cast (vtfn controller 24) _fpointer (_fun _pointer -> _int32)))
    (close-ctrl controller)
    (let loop ([deadline (+ (current-inexact-milliseconds) 200)])
      (define msg (malloc (ctype-sizeof _MSG) 'atomic))
      (when (PeekMessageW msg #f 0 0 PM_REMOVE)
        (TranslateMessage msg)
        (DispatchMessageW msg))
      (when (< (current-inexact-milliseconds) deadline)
        (sleep 0.01)
        (loop deadline)))))

;; COM out-param call helpers: always surface the HRESULT.
(define (call-with-out obj idx)
  (define fn
    (cast (vtfn obj idx)
          _fpointer
          (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))))
  (fn obj))

(define (cwv-getter idx) ; LPCWSTR-returning getters (get_Source / get_DocumentTitle)
  (lambda (cwv)
    (and cwv
         (let ()
           (define fn
             (cast (vtfn cwv idx)
                   _fpointer
                   (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))))
           (define-values (hr p) (fn cwv))
           (and (= hr S_OK) (wstr->string p))))))

;; ---- native transport (docs/architecture.md) ----
;; vtable indices verified against the official WebView2.h (Microsoft.Web.
;; WebView2 nupkg): ICoreWebView2 PostWebMessageAsJson = 32,
;; add_WebMessageReceived = 34, add_WebResourceRequested = 55,
;; AddWebResourceRequestedFilter = 57; WebMessageReceivedEventArgs
;; TryGetWebMessageAsString = 5; WebResourceRequestedEventArgs get_Request
;; = 3 / put_Response = 5; WebResourceRequest get_Uri = 3; Environment
;; CreateWebResourceResponse = 4.
;;
;; The resource filter and both event handlers are registered in the
;; controller callback BEFORE the first navigation; the page then loads
;; from glaze://app/ and never sees the loopback server. Deliveries
;; (GLZ1 responses, event batches) are queued and posted from the window's
;; own pump thread via PostWebMessageAsJson.

(define (win-scheme-url args)
  (define-values (hr req) (call-with-out args 3)) ; get_Request
  (and (= hr S_OK) req ((cwv-getter 3) req))) ; get_Uri

(define (win-scheme-serve! wiring args)
  (trace "scheme: enter")
  (define transport (native-wiring-transport wiring))
  (define env (native-wiring-env wiring))
  (trace "scheme: wiring ok, env=~s" (and env #t))
  (define (respond! mime data)
    (trace "scheme: respond mime=~a len=~a" (bytes->string/latin-1 mime) (bytes-length data))
    (define stream (and SHCreateMemStream (SHCreateMemStream data (bytes-length data))))
    (define make-resp
      (cast (vtfn env 4)
            _fpointer
            (_fun _pointer
                  _pointer
                  _int
                  _pointer
                  _pointer
                  (p : (_ptr o _pointer))
                  ->
                  (r : _int32)
                  ->
                  (values r p))))
    (define bare-mime (car (regexp-split #rx";" (bytes->string/latin-1 mime))))
    (define headers
      (wstr (apply string-append
                   "Content-Type: "
                   bare-mime
                   "\r\nX-Content-Type-Options: nosniff"
                   (for/list ([entry (in-list (native-transport-csp-headers transport))])
                     (string-append "\r\n" (car entry) ": " (cdr entry))))))
    (define-values (hr resp) (make-resp env stream 200 (wstr "OK") headers))
    (unless (= hr S_OK)
      (error 'win-scheme-serve! "CreateWebResourceResponse failed: 0x~x" (bitwise-and hr #xffffffff)))
    (define put (cast (vtfn args 5) _fpointer (_fun _pointer _pointer -> _int32)))
    (put args resp))
  (define (respond-status! code)
    (respond! #"text/plain" (string->bytes/utf-8 (format "~a" code))))
  (with-handlers ([exn:fail? (lambda (e)
                               (log "scheme: EXN ~a" (exn-message e))
                               ((current-glaze-error-reporter) e "glz1:scheme")
                               (respond-status! 404))])
    (define url (win-scheme-url args))
    (trace "scheme: url=~s" url)
    (define segments (native-scheme-segments url))
    (cond
      [(not segments) (respond-status! 404)]
      [(equal? segments '("glaze" "api.js"))
       (native-transport-count-resource! transport)
       (respond! #"application/javascript; charset=utf-8"
                 (string->bytes/utf-8 (native-api-client-js (native-transport-routes transport))))]
      [(equal? segments '("glaze" "api.d.ts"))
       (native-transport-count-resource! transport)
       (respond! #"application/typescript; charset=utf-8"
                 (string->bytes/utf-8 (generate-api-declarations
                                       (native-transport-routes transport))))]
      ;; The bridge surface (/glaze/*) is message-handler-only here; never
      ;; fall back to index.html for it.
      [(and (pair? segments) (string=? (first segments) "glaze")) (respond-status! 404)]
      [else
       (define-values (mime data) (static-resource (native-transport-public-dir transport) segments))
       (if mime
           (begin
             (native-transport-count-resource! transport)
             (respond! mime data))
           (respond-status! 404))])))

(define (win-handle-message! wiring args)
  (trace "message: enter")
  (define transport (native-wiring-transport wiring))
  (define fn
    (cast (vtfn args 5) ; TryGetWebMessageAsString
          _fpointer
          (_fun _pointer (p : (_ptr o _pointer)) -> (r : _int32) -> (values r p))))
  (define-values (hr p) (fn args))
  (trace "message: hr=0x~x" (bitwise-and hr #xffffffff))
  (when (= hr S_OK)
    (define text (wstr->string p))
    (when (string? text)
      (trace "message: envelope received")
      ;; WebView2 invokes this on a COM/FFI callback stack. Enqueuing via
      ;; async-channel-put may yield inside Racket atomic mode and abort the
      ;; process; stash here and forward from the full Racket pump thread.
      (native-transport-message-deferred! transport text))))

(struct native-wiring (transport env) #:transparent)

;; JavaScript snippets awaiting PostWebMessageAsJson on the window's pump
;; thread: (cons cwv-box js-string). The box indirection is safe against a
;; late delivery after close (the box just still holds the old interface).
(define (drain-deliveries! wv)
  (define queue (win:webview-deliver-queue wv))
  (let loop ()
    (define v (and queue (async-channel-try-get queue)))
    (when v
      ;; The queue entry carries the ICoreWebView2 pointer directly (the
      ;; struct's cwv-box field holds the interface, not a box). WebView2's
      ;; PostWebMessageAsJson wants the BARE JSON carrier, not the JS
      ;; snippet; the page's message-event bridge turns it into
      ;; __glz1Deliver.
      (define cwv (car v))
      (when cwv
        (with-handlers ([exn:fail? (lambda (e) (log "deliver: EXN ~a" (exn-message e)))])
          (define post (cast (vtfn cwv 32) _fpointer (_fun _pointer _pointer -> _int32)))
          (define hr (post cwv (wstr (native-delivery-json (cdr v)))))
          (trace "deliver: post hr=0x~x" (bitwise-and hr #xffffffff))))
      (loop))))

(define (open-webview url
                      #:title [title "Glaze"]
                      #:width [width 1024]
                      #:height [height 768]
                      #:devtools? [devtools? #f]
                      #:native-transport [native-transport #f]
                      #:on-close [on-close (lambda () (void))])
  (unless (supported?)
    (error 'open-webview "WebView2 backend unavailable"))
  (when native-transport
    (unless (native-transport? native-transport)
      (raise-argument-error 'open-webview "native-transport?" native-transport)))
  (when CoInitialize
    (CoInitialize #f))

  (define wv
    (win:webview (box #f) #f #f url (box #f) (box #f) (box #f) #f (make-async-channel #f) on-close))
  (define instance (GetModuleHandleW #f))

  ;; controller callback: AddRef both interfaces into the handle, Navigate,
  ;; signal ready. WebView2 refuses top-level navigation to custom schemes
  ;; (the reason Tauri uses http://tauri.localhost on Windows), so the page
  ;; loads from http://glaze.localhost/ and the resource filter intercepts
  ;; it before any network access.
  (define url-ptr
    (wstr (if native-transport
              (native-origin-url url)
              url)))
  (define ctrl-handler
    (make-com-handler
     IID-CtrlHandler
     (lambda (errcode controller)
       (cond
         ;; Teardown race (glaze#146): destroying the parent HWND aborts
         ;; in-flight controller work and the runtime delivers E_ABORT
         ;; through this callback. Once the window is marked closed that
         ;; abort is expected teardown, not a creation failure.
         [(and (= errcode E_ABORT) (unbox (win:webview-closed?-box wv)))
          (log "controller E_ABORT during teardown ignored (glaze#146)")]
         [(not (= errcode 0))
          (begin
            (log "controller callback error 0x~x" (bitwise-and errcode #xffffffff))
            (set-box!
             (win:webview-error-box wv)
             (error 'open-webview "CreateController failed: 0x~x" (bitwise-and errcode #xffffffff))))]
         [else
          (let ()
            ;; AddRef keeps them valid beyond the callback (same STA thread).
            (define addref (cast (vtfn controller 1) _fpointer (_fun _pointer -> _uint32)))
            (addref controller)
            (set-win:webview-controller-box! wv controller)
            (define-values (hr cwv) (call-with-out controller 25)) ; get_CoreWebView2
            (if (not (= hr S_OK))
                (begin
                  (log "get_CoreWebView2 failed 0x~x" (bitwise-and hr #xffffffff))
                  (set-box!
                   (win:webview-error-box wv)
                   (error 'open-webview "get_CoreWebView2 failed: 0x~x" (bitwise-and hr #xffffffff))))
                (let ()
                  (addref cwv)
                  (set-win:webview-cwv-box! wv cwv)
                  ;; Size the WebView to the client area (put_Bounds = 6);
                  ;; without this the controller keeps default bounds.
                  (define rc (make-RECT 0 0 0 0))
                  (GetClientRect (unbox (win:webview-hwnd-box wv)) rc)
                  (define put-bounds
                    (cast (vtfn controller 6) _fpointer (_fun _pointer _RECT -> _int32)))
                  (put-bounds controller (make-RECT 0 0 (RECT-right rc) (RECT-bottom rc)))
                  ;; Native transport: bootstrap + scheme filter + both
                  ;; event handlers must be in place BEFORE the first
                  ;; navigation, so the page never touches a TCP port.
                  (when native-transport
                    (trace "native: registering handlers")
                    (define wiring (native-wiring native-transport (unbox env-box)))
                    ;; AddScriptToExecuteOnDocumentCreated(script,
                    ;; handler) — the completion handler is a third [in]
                    ;; parameter (nullable); omitting it made WebView2 read
                    ;; a garbage stack value and call it later: segfault.
                    (define add-script
                      (cast (vtfn cwv 27) _fpointer (_fun _pointer _pointer _pointer -> _int32)))
                    (add-script cwv (wstr native-bootstrap-js) #f)
                    (define add-filter
                      (cast (vtfn cwv 57) _fpointer (_fun _pointer _pointer _int -> _int32)))
                    (add-filter cwv (wstr "http://glaze.localhost/*") 0) ; WEB_RESOURCE_CONTEXT_ALL
                    (define wrr-handler
                      (make-com-event-handler IID-WebResourceHandler
                                              (lambda (_sender args)
                                                (win-scheme-serve! wiring args))))
                    (trace "native: script+filter done")
                    (define add-wrr
                      (cast (vtfn cwv 55)
                            _fpointer
                            (_fun _pointer
                                  _pointer
                                  (t : (_ptr o _uintptr))
                                  ->
                                  (r : _int32)
                                  ->
                                  (values r t))))
                    (trace "native: wrr added")
                    (add-wrr cwv wrr-handler)
                    (trace "native: wmr registering")
                    (define wmr-handler
                      (make-com-event-handler IID-WebMessageHandler
                                              (lambda (_sender args)
                                                (win-handle-message! wiring args))))
                    (define add-wmr
                      (cast (vtfn cwv 34)
                            _fpointer
                            (_fun _pointer
                                  _pointer
                                  (t : (_ptr o _uintptr))
                                  ->
                                  (r : _int32)
                                  ->
                                  (values r t))))
                    (add-wmr cwv wmr-handler)
                    (native-transport-set-deliver! native-transport
                                                   (lambda (js)
                                                     (async-channel-put (win:webview-deliver-queue wv)
                                                                        (cons (win:webview-cwv-box wv)
                                                                              js)))))
                  (define nav (cast (vtfn cwv 5) _fpointer (_fun _pointer _pointer -> _int32)))
                  (define nav-hr (nav cwv url-ptr))
                  (trace "Navigate hr=0x~x" (bitwise-and nav-hr #xffffffff))
                  (when devtools?
                    (define od (cast (vtfn cwv 51) _fpointer (_fun _pointer -> _int32)))
                    (od cwv))
                  (set-box! (win:webview-ready?-box wv) #t))))]))))

  ;; env handler: immediately CreateController. The environment is AddRef'd
  ;; and shared with the controller callback (CreateWebResourceResponse
  ;; needs it to build scheme responses).
  (define env-box (box #f))
  (define env-handler
    (make-com-handler
     IID-EnvHandler
     (lambda (errcode env)
       (if (not (= errcode 0))
           (begin
             (log "environment callback error 0x~x" (bitwise-and errcode #xffffffff))
             (set-box! (win:webview-error-box wv)
                       (error 'open-webview
                              "CreateEnvironment failed: 0x~x"
                              (bitwise-and errcode #xffffffff))))
           (let ()
             (define addref (cast (vtfn env 1) _fpointer (_fun _pointer -> _uint32)))
             (addref env)
             (set-box! env-box env)
             (define create-ctrl
               (cast (vtfn env 3) _fpointer (_fun _pointer _pointer _pointer -> _int32)))
             (create-ctrl env (unbox (win:webview-hwnd-box wv)) ctrl-handler))))))

  ;; Init runs on the calling thread so COM callbacks fire during our own
  ;; PeekMessage pump.
  (define (do-init)
    (with-handlers ([exn:fail? (lambda (e) (set-box! (win:webview-error-box wv) e))])
      (define wc
        (cast (malloc (ctype-sizeof _WNDCLASSEXW) 'raw _pointer) _pointer _WNDCLASSEXW-pointer))
      (memset wc 0 (ctype-sizeof _WNDCLASSEXW))
      (set-WNDCLASSEXW-cbSize! wc (ctype-sizeof _WNDCLASSEXW))
      (set-WNDCLASSEXW-lpfnWndProc! wc wndproc-cptr)
      (set-WNDCLASSEXW-hInstance! wc instance)
      (set-WNDCLASSEXW-lpszClassName! wc class-name)
      ;; Class icons are shared (LR_SHARED), so Windows owns their lifetime.
      (define small-icon-size
        (if GetSystemMetrics
            (GetSystemMetrics SM_CXSMICON)
            16))
      (define big-icon (load-app-icon instance 0 0 (bitwise-ior LR_DEFAULTSIZE LR_SHARED)))
      (define small-icon
        (load-app-icon instance
                       small-icon-size
                       (if GetSystemMetrics
                           (GetSystemMetrics SM_CYSMICON)
                           16)
                       LR_SHARED))
      (set-WNDCLASSEXW-hIcon! wc big-icon)
      (set-WNDCLASSEXW-hIconSm! wc small-icon)
      (RegisterClassExW wc)
      (unless big-icon
        (log "warning: no APPLICATION icon group in the executable; window uses the default icon"))

      (define hwnd
        (CreateWindowExW 0
                         class-name
                         (wstr title)
                         WS_OVERLAPPEDWINDOW
                         CW_USEDEFAULT
                         CW_USEDEFAULT
                         width
                         height
                         0
                         #f
                         instance
                         #f))
      (set-box! (win:webview-hwnd-box wv) hwnd)
      (hash-set! wndprocs (cast hwnd _pointer _uintptr) wv)
      (apply-system-titlebar-theme! hwnd)
      (ShowWindow hwnd SW_SHOW)

      (define data-folder (wstr (path->string (new-webview2-data-folder))))
      (define env-options
        (and (allow-programmatic-playback?)
             CoTaskMemAlloc
             (make-environment-options "--autoplay-policy=no-user-gesture-required")))
      (define hr (CreateCoreWebView2EnvironmentWithOptions #f data-folder env-options env-handler))
      (unless (= (bitwise-and hr #xffffffff) 0)
        (error 'open-webview
               "CreateCoreWebView2Environment failed: 0x~x"
               (bitwise-and hr #xffffffff)))

      ;; Pump until the controller callback signals ready (or timeout).
      (let loop ([deadline (+ (current-inexact-milliseconds) 15000)])
        (unless (or (unbox (win:webview-ready?-box wv))
                    (unbox (win:webview-error-box wv))
                    (> (current-inexact-milliseconds) deadline))
          (define msg (malloc (ctype-sizeof _MSG) 'atomic))
          (when (PeekMessageW msg #f 0 0 PM_REMOVE)
            (TranslateMessage msg)
            (DispatchMessageW msg))
          (sleep 0.02)
          (loop deadline)))))

  (do-init)
  (when (unbox (win:webview-error-box wv))
    (raise (unbox (win:webview-error-box wv))))

  ;; Spawn a thread for the ongoing message pump. Deliveries ride the same
  ;; loop: PostWebMessageAsJson from the thread that services this window.
  (define (pump-loop)
    (unless (unbox (win:webview-closed?-box wv))
      (define msg (malloc (ctype-sizeof _MSG) 'atomic))
      (when (PeekMessageW msg #f 0 0 PM_REMOVE)
        (TranslateMessage msg)
        (DispatchMessageW msg))
      ;; The same discipline as WKWebView: never invoke the blocking
      ;; transport inbox from a COM callback stack.
      (when native-transport
        (for ([raw (in-list (native-transport-take-deferred! native-transport))])
          (native-transport-message! native-transport raw)))
      (drain-deliveries! wv)
      (sleep 0.01)
      (pump-loop)))
  (set-win:webview-thread! wv (thread pump-loop))
  wv)

(define (close wv)
  (unless (unbox (win:webview-closed?-box wv))
    (set-box! (win:webview-closed?-box wv) #t)
    ((win:webview-on-close wv))
    (teardown-controller! wv)
    (define hwnd (unbox (win:webview-hwnd-box wv)))
    (when hwnd
      (DestroyWindow-maybe hwnd)
      (PostMessageW hwnd WM_QUIT 0 0))
    (sync/timeout 1 (thread-dead-evt (win:webview-thread wv)))))

;; Post-open Navigate against the retained ICoreWebView2 (same STA thread).
(define (navigate wv url)
  (set-win:webview-url! wv url)
  (define cwv (win:webview-cwv-box wv))
  (when cwv
    (define nav (cast (vtfn cwv 5) _fpointer (_fun _pointer _pointer -> _int32)))
    (nav cwv (wstr url))))

;; Verification APIs: synchronous getters against the retained interface.
(define title (lambda (wv) ((cwv-getter 48) (win:webview-cwv-box wv)))) ; get_DocumentTitle
(define url (lambda (wv) ((cwv-getter 4) (win:webview-cwv-box wv)))) ; get_Source

;; Window capture is owned by glaze/private/windows-capture (glaze#140):
;; PrintWindow into a top-down DIB, then a BMP whose rows are stored in
;; bottom-up file order. A closed window or a failed stage returns #f after
;; logging the underlying reason.
(define (capture! wv [dest #f])
  (and (not (unbox (win:webview-closed?-box wv)))
       (let ([hwnd (unbox (win:webview-hwnd-box wv))])
         (and hwnd
              (with-handlers ([exn:fail? (lambda (e)
                                           (log "capture failed: ~a" (exn-message e))
                                           #f)])
                (capture-window->png hwnd dest))))))

;; ---- window controls ----
;; ---- window controls ----
(define SetWindowTextW
  (get-ffi-obj "SetWindowTextW" user32 (_fun _pointer _pointer -> _bool) (lambda () #f)))
(define SetWindowPos
  (get-ffi-obj "SetWindowPos"
               user32
               (_fun _pointer _pointer _int _int _int _int _uint -> _bool)
               (lambda () #f)))
(define GetWindowRect
  (get-ffi-obj "GetWindowRect" user32 (_fun _pointer _RECT-pointer -> _bool) (lambda () #f)))
(define GetWindowPlacement
  (get-ffi-obj "GetWindowPlacement"
               user32
               (_fun _pointer _WINDOWPLACEMENT-pointer -> _bool)
               (lambda () #f)))
(define SetWindowPlacement
  (get-ffi-obj "SetWindowPlacement"
               user32
               (_fun _pointer _WINDOWPLACEMENT-pointer -> _bool)
               (lambda () #f)))
(define IsZoomed (get-ffi-obj "IsZoomed" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define GetSystemMetrics (get-ffi-obj "GetSystemMetrics" user32 (_fun _int -> _int) (lambda () #f)))
(define GetWindowLongPtrW
  (get-ffi-obj "GetWindowLongPtrW" user32 (_fun _pointer _int -> _intptr) (lambda () #f)))
(define SetWindowLongPtrW
  (get-ffi-obj "SetWindowLongPtrW" user32 (_fun _pointer _int _intptr -> _intptr) (lambda () #f)))

(define SWP_NOMOVE #x0002)
(define SWP_NOZORDER #x0004)
(define SM_CXSCREEN 0)
(define SM_CYSCREEN 1)
(define SM_XVIRTUALSCREEN 76)
(define SM_YVIRTUALSCREEN 77)
(define SM_CXVIRTUALSCREEN 78)
(define SM_CYVIRTUALSCREEN 79)
(define GWL_STYLE -16)
(define WS_MAXIMIZEBOX #x00010000)
(define WS_MINIMIZEBOX #x00020000)
(define SW_MAXIMIZE 3)
(define SW_RESTORE 9)
(define SW_SHOWNORMAL 1)

(define (set-title! wv t)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (and hwnd SetWindowTextW (SetWindowTextW hwnd (wstr t))))

(define (set-size! wv width height)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (and hwnd
       SetWindowPos
       (SetWindowPos hwnd #f 0 0 width height (bitwise-ior SWP_NOMOVE SWP_NOZORDER))))

(define (set-fullscreen! wv on?)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (and hwnd ShowWindow (ShowWindow hwnd (if on? SW_MAXIMIZE SW_RESTORE))))

(define (geometry wv)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (and hwnd
       (let* ([placement (make-WINDOWPLACEMENT (ctype-sizeof _WINDOWPLACEMENT)
                                               0
                                               0
                                               (make-POINT 0 0)
                                               (make-POINT 0 0)
                                               (make-RECT 0 0 0 0)
                                               (make-RECT 0 0 0 0))]
              [placement-ok? (and GetWindowPlacement (GetWindowPlacement hwnd placement))]
              [rect (if placement-ok?
                        (WINDOWPLACEMENT-rcNormalPosition placement)
                        (make-RECT 0 0 0 0))]
              [rect-ok? (or placement-ok? (and GetWindowRect (GetWindowRect hwnd rect)))])
         (and rect-ok?
              (list (RECT-left rect)
                    (RECT-top rect)
                    (- (RECT-right rect) (RECT-left rect))
                    (- (RECT-bottom rect) (RECT-top rect))
                    (and IsZoomed (IsZoomed hwnd) #t))))))

(define (set-geometry! wv x y width height maximized?)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (and hwnd
       (let ([placement (make-WINDOWPLACEMENT (ctype-sizeof _WINDOWPLACEMENT)
                                              0
                                              (if maximized? SW_MAXIMIZE SW_SHOWNORMAL)
                                              (make-POINT 0 0)
                                              (make-POINT 0 0)
                                              (make-RECT x y (+ x width) (+ y height))
                                              (make-RECT 0 0 0 0))])
         (cond
           [(and GetWindowPlacement SetWindowPlacement (GetWindowPlacement hwnd placement))
            (set-WINDOWPLACEMENT-showCmd! placement (if maximized? SW_MAXIMIZE SW_SHOWNORMAL))
            (set-WINDOWPLACEMENT-rcNormalPosition! placement (make-RECT x y (+ x width) (+ y height)))
            (SetWindowPlacement hwnd placement)]
           [SetWindowPos
            (and (SetWindowPos hwnd #f x y width height SWP_NOZORDER)
                 (or (not ShowWindow) (ShowWindow hwnd (if maximized? SW_MAXIMIZE SW_RESTORE))))]
           [else #f]))))

(define (screen-area)
  (and GetSystemMetrics
       (let* ([width (GetSystemMetrics SM_CXVIRTUALSCREEN)]
              [height (GetSystemMetrics SM_CYVIRTUALSCREEN)]
              [virtual? (and (> width 0) (> height 0))])
         (list (if virtual?
                   (GetSystemMetrics SM_XVIRTUALSCREEN)
                   0)
               (if virtual?
                   (GetSystemMetrics SM_YVIRTUALSCREEN)
                   0)
               (if virtual?
                   width
                   (GetSystemMetrics SM_CXSCREEN))
               (if virtual?
                   height
                   (GetSystemMetrics SM_CYSCREEN))))))

(define SetForegroundWindow
  (get-ffi-obj "SetForegroundWindow" user32 (_fun _pointer -> _bool) (lambda () #f)))
(define (focus! wv)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (and hwnd SetForegroundWindow (SetForegroundWindow hwnd)))

;; ---- menu bar ----
;; A Win32 HMENU attached with SetMenu; selections arrive as WM_COMMAND with
;; the menu id in LOWORD(wParam), dispatched through the id-allocator to the
;; Racket thunk. Accelerators are display-only here ("Ctrl+O" shows
;; right-aligned in the item; wiring real keys needs an accelerator table +
;; TranslateAccelerator in the pump — documented v1 limitation).

(define menu-sema (make-semaphore 1))
(define menu-allocator (make-id-allocator))

(define (menu-action-lookup id)
  (call-with-semaphore menu-sema (lambda () (id-allocator-lookup menu-allocator id))))

(define MF_STRING #x00000000)
(define MF_SEPARATOR #x00000800)
(define MF_POPUP #x00000010)

(define CreateMenu (and user32 (get-ffi-obj "CreateMenu" user32 (_fun -> _pointer) (lambda () #f))))
(define DestroyMenu
  (and user32 (get-ffi-obj "DestroyMenu" user32 (_fun _pointer -> _bool) (lambda () #f))))
(define AppendMenuW
  (and user32
       (get-ffi-obj "AppendMenuW"
                    user32
                    (_fun _pointer _uint _uintptr _pointer -> _bool)
                    (lambda () #f))))
(define SetMenuW
  (and user32 (get-ffi-obj "SetMenu" user32 (_fun _pointer _pointer -> _bool) (lambda () #f))))
(define DrawMenuBar
  (and user32 (get-ffi-obj "DrawMenuBar" user32 (_fun _pointer -> _bool) (lambda () #f))))

(define (win-build-menu! m)
  (define hmenu (CreateMenu))
  (for ([e (in-list (menu-items m))])
    (cond
      [(menu-separator? e) (AppendMenuW hmenu MF_SEPARATOR 0 #f)]
      [else
       (define id
         (call-with-semaphore menu-sema
                              (lambda ()
                                (id-allocator-register! menu-allocator (menu-item-action e)))))
       (define label
         (if (menu-item-accel e)
             (format "~a\t~a" (menu-item-label e) (menu-item-accel e))
             (menu-item-label e)))
       (AppendMenuW hmenu MF_STRING id (wstr label))]))
  hmenu)

(define (set-menu! wv menus)
  (define hwnd (unbox (win:webview-hwnd-box wv)))
  (unless (and hwnd CreateMenu AppendMenuW SetMenuW)
    (error 'set-menu! "Win32 menu API unavailable"))
  (define menubar (CreateMenu))
  (for ([m (in-list menus)])
    (unless (menu? m)
      (error 'set-menu! "expected a menu? value, got: ~a" m))
    (define hsub (win-build-menu! m))
    (AppendMenuW menubar MF_POPUP (cast hsub _pointer _uintptr) (wstr (menu-title m))))
  (unless (and (SetMenuW hwnd menubar) (DrawMenuBar hwnd))
    (error 'set-menu! "SetMenu failed"))
  (void))

(define (closed? wv)
  (unbox (win:webview-closed?-box wv)))

#lang racket/base
;; Tray click events and Explorer-restart recovery (glaze#141).
;;
;; `make-tray` accepted `#:on-event` on every backend, but no backend ever
;; invoked it, and the Windows icon vanished for good when Explorer
;; restarted. The Windows section drives the real notify-icon window with
;; the same messages the shell sends; other platforms check the dispatcher
;; contract only. GLAZE_TEST_NO_TRAY=1 skips hosts without a notification
;; area (the public make-tray fallback is still covered by main.rkt).

(require ffi/unsafe
         rackunit
         glaze/tray/main)

(test-case "the public dispatcher forwards #:on-event to the backend"
  (check-true (procedure? make-tray))
  (define-values (required-keywords optional-keywords) (procedure-keywords make-tray))
  (check-not-false (memq '#:on-event (append required-keywords optional-keywords))
                   "make-tray accepts #:on-event"))

(when (eq? (system-type 'os) 'unix)
  ;; The dispatcher dynamic-requires this module for every Linux tray; a
  ;; module-level use ahead of its definition made it fail to load on every
  ;; Linux host (the error surfaced only in a package, where the stub
  ;; fallback was missing too). A runner without libayatana-appindicator must
  ;; still load the module and answer #f.
  (test-case "the Linux backend module loads and reports its support"
    (define supported? (dynamic-require 'glaze/tray/tray-linux 'supported?))
    (check-true (procedure? supported?) "tray-linux exports supported?")
    (check-true (boolean? (supported?)) "supported? answers with a boolean")))

(when (and (eq? (system-type 'os) 'windows) (not (getenv "GLAZE_TEST_NO_TRAY")))
  (define mod-make-tray (dynamic-require 'glaze/tray/tray-windows 'make-tray))
  (define mod-close (dynamic-require 'glaze/tray/tray-windows 'close))
  (define mod-hwnd (dynamic-require 'glaze/tray/tray-windows 'win:tray-hwnd))
  (define mod-set-tooltip! (dynamic-require 'glaze/tray/tray-windows 'set-tooltip!))

  (define user32 (ffi-lib "user32"))
  (define PostMessageW
    (get-ffi-obj "PostMessageW" user32 (_fun _pointer _uint _uintptr _intptr -> _bool)))
  (define RegisterWindowMessageW
    (get-ffi-obj "RegisterWindowMessageW" user32 (_fun _string/utf-16 -> _uint)))
  (define IsWindow (get-ffi-obj "IsWindow" user32 (_fun _pointer -> _bool)))

  ;; Same values as the backend: WM_USER carries tray mouse events in lParam.
  (define TRAY_CALLBACK_MSG 1024)
  (define WM_LBUTTONUP 514)
  (define WM_LBUTTONDBLCLK 515)

  (define (shell-sends! hwnd msg lparam)
    (check-true (PostMessageW hwnd msg 0 lparam) "PostMessageW delivers the shell message"))

  (test-case "left click and double click reach on-event"
    (define events (make-channel))
    (define t
      (mod-make-tray #:icon #f
                     #:tooltip "on-event test"
                     #:menu '()
                     #:on-event (lambda (e) (channel-put events e))))
    (define hwnd (mod-hwnd t))
    (check-not-false hwnd "the tray owns a window")
    (shell-sends! hwnd TRAY_CALLBACK_MSG WM_LBUTTONUP)
    (check-equal? (sync/timeout 5 events) 'click "WM_LBUTTONUP reports 'click")
    (shell-sends! hwnd TRAY_CALLBACK_MSG WM_LBUTTONDBLCLK)
    (check-equal? (sync/timeout 5 events) 'double-click "WM_LBUTTONDBLCLK reports 'double-click")
    (mod-close t))

  (test-case "a raising on-event does not kill the tray message loop"
    (define attempts (box 0))
    (define t
      (mod-make-tray #:icon #f
                     #:tooltip "raising on-event"
                     #:menu '()
                     #:on-event (lambda (_e)
                                  (set-box! attempts (add1 (unbox attempts)))
                                  (error 'on-event "boom"))))
    (define hwnd (mod-hwnd t))
    (parameterize ([current-error-port (open-output-string)])
      (shell-sends! hwnd TRAY_CALLBACK_MSG WM_LBUTTONUP)
      ;; A raising handler must be contained inside the WindowProc; wait for
      ;; the first attempt to be observed before sending the second.
      (define deadline (+ (current-inexact-milliseconds) 5000))
      (let loop ()
        (when (and (zero? (unbox attempts)) (< (current-inexact-milliseconds) deadline))
          (sleep 0.02)
          (loop)))
      (shell-sends! hwnd TRAY_CALLBACK_MSG WM_LBUTTONUP)
      (define second-deadline (+ (current-inexact-milliseconds) 5000))
      (let loop ()
        (when (and (< (unbox attempts) 2) (< (current-inexact-milliseconds) second-deadline))
          (sleep 0.02)
          (loop))))
    (check-equal? (unbox attempts) 2 "the message loop keeps delivering after a handler error")
    (check-not-exn (lambda () (mod-set-tooltip! t "still alive")) "the tray stays usable")
    (mod-close t))

  (test-case "TaskbarCreated keeps the tray alive and responsive"
    (define events (make-channel))
    (define t
      (mod-make-tray #:icon #f
                     #:tooltip "taskbar-created test"
                     #:menu '()
                     #:on-event (lambda (e) (channel-put events e))))
    (define hwnd (mod-hwnd t))
    ;; Explorer broadcasts this registered message to top-level windows when
    ;; it (re)starts. Message-only windows never receive it, which is why the
    ;; backend must own a real (hidden) window.
    (define taskbar-created (RegisterWindowMessageW "TaskbarCreated"))
    (check-true (> taskbar-created 0) "TaskbarCreated is a registered window message")
    (shell-sends! hwnd taskbar-created 0)
    ;; Give the tray thread time to run the re-add, then prove the window
    ;; and its callback are still functional.
    (sleep 0.5)
    (check-true (IsWindow hwnd) "the tray window survives TaskbarCreated")
    (shell-sends! hwnd TRAY_CALLBACK_MSG WM_LBUTTONUP)
    (check-equal? (sync/timeout 5 events) 'click "clicks are delivered after TaskbarCreated")
    (mod-close t)))

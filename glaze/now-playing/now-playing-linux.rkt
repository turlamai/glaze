#lang racket/base

;; Linux host-owned MPRIS backend (glaze#153): the host process owns
;; org.mpris.MediaPlayer2.<identifier> on the session bus via GIO/GDBus,
;; independent of WebKitGTK's MediaSession bridge (WebKit bug 279362).
;;
;; GDBus callbacks (method calls, property reads) are dispatched on the
;; GLib main context; glaze's Linux pump already iterates it, so command
;; handlers run on the pump thread. Publication (emit_signal) is
;; thread-safe from any Racket thread.
;;
;; Struct layouts and function signatures follow the official GIO headers
;; (gdbusconnection.h, gdbusmethodinvocation.h, gvariant.h): GDBusInterfaceVTable
;; is three function pointers plus 8 gpointer padding; GVariantBuilder is a
;; union whose largest member is gpointer x[16] (we over-allocate).

(require ffi/unsafe
         ffi/unsafe/define
         ffi/unsafe/atomic
         glaze/ffi-discovery
         racket/string
         "../private/main-context-registry.rkt")

(provide supported?
         publish!
         os-info
         set-handler!
         diagnostics)

(define gio (ffi-lib* "libgio-2.0" '("0" "")))

(define-ffi-definer defgio gio)

;; GMainContext lives in glib, not gio. The bus connection binds to the
;; thread-default context at g_bus_get_sync time; hosts acquire it lazily
;; from request threads, so the backend owns a dedicated context and pumps
;; it itself instead of relying on the embedder's loop (podlens#63: an
;; unpumped bound context answers every external Properties.Get with
;; NoReply).
(define glib (ffi-lib* "libglib-2.0" '("0" "")))
(define-ffi-definer defglib glib)
(defglib g_main_context_new (_fun -> _pointer))
(defglib g_main_context_push_thread_default (_fun _pointer -> _void))
(defglib g_main_context_pop_thread_default (_fun _pointer -> _void))
(defglib g_main_context_iteration (_fun _pointer _bool -> _bool))
(defglib g_main_context_default (_fun -> _pointer))
(defglib g_main_context_get_thread_default (_fun -> _pointer))

(define _GVariant _pointer)
(define _GDBusConnection _pointer)

(defgio g_bus_get_sync (_fun _int _pointer _pointer -> _GDBusConnection))
;; Private connection: g_bus_get_sync returns a process-wide singleton whose
;; context binding is fixed by whoever created it first (GTK/GNetworkMonitor
;; may pre-create it on the default context). A private connection binds to
;; our pushed context deterministically.
(defgio g_dbus_connection_new_for_address_sync
        (_fun _string _int _pointer _pointer _pointer -> _GDBusConnection))
(defgio g_dbus_connection_get_unique_name (_fun _GDBusConnection -> _string))
(defgio g_dbus_connection_register_object
        (_fun _GDBusConnection _string _pointer _pointer _pointer _pointer _pointer -> _uint))
(defgio g_dbus_connection_emit_signal
        (_fun _GDBusConnection _pointer _string _string _string _GVariant _pointer -> _bool))
(defgio g_dbus_connection_call_sync
        (_fun _GDBusConnection
              _string
              _string
              _string
              _string
              _GVariant
              _pointer
              _int
              _int
              _pointer
              _pointer
              ->
              _GVariant))
(defgio g_bus_own_name_on_connection
        (_fun _GDBusConnection _string _int _pointer _pointer _pointer _pointer _pointer -> _uint))
(defgio g_dbus_node_info_new_for_xml (_fun _string _pointer -> _pointer))
(defgio g_dbus_method_invocation_return_value (_fun _pointer _GVariant -> _void))
(defgio g_dbus_method_invocation_return_error (_fun _pointer _int _int _string -> _void))
(defgio g_variant_new_string (_fun _string -> _GVariant))
(defgio g_variant_new_boolean (_fun _bool -> _GVariant))
(defgio g_variant_new_int64 (_fun _int64 -> _GVariant))
(defgio g_variant_new_double (_fun _double -> _GVariant))
(defgio g_variant_new_strv (_fun _pointer _int64 -> _GVariant))
(defgio g_variant_new_x (_fun _string _int64 -> _GVariant) #:c-id g_variant_new)
(defgio g_variant_new_props
        (_fun _string _string _GVariant _GVariant -> _GVariant)
        #:c-id g_variant_new)
;; Array slots of g_variant_new consume the builder (ending it internally);
;; this is the form proven safe by the PropertiesChanged emit path.
(defgio g_variant_new_dict (_fun _string _pointer -> _GVariant) #:c-id g_variant_new)
(defgio g_variant_ref_sink (_fun _GVariant -> _GVariant))
(defgio g_variant_get_string (_fun _GVariant _pointer -> _string))
(defgio g_variant_get_boolean (_fun _GVariant -> _bool))
(defgio g_variant_get_int64 (_fun _GVariant -> _int64))
(defgio g_variant_get_double (_fun _GVariant -> _double))
(defgio g_variant_builder_init (_fun _pointer _string -> _void))
(defgio g_variant_builder_add_sv
        (_fun _pointer _string _string _GVariant -> _void)
        #:c-id g_variant_builder_add)
(defgio g_variant_builder_end (_fun _pointer -> _GVariant))
(defgio g_variant_get_child_value (_fun _GVariant _int64 -> _GVariant))

;; GDBusInterfaceVTable: method_call, get_property, set_property, padding[8].
(define-cstruct _GDBusInterfaceVTable
                ([method_call _fpointer] [get_property _fpointer]
                                         [set_property _fpointer]
                                         [pad0 _pointer]
                                         [pad1 _pointer]
                                         [pad2 _pointer]
                                         [pad3 _pointer]
                                         [pad4 _pointer]
                                         [pad5 _pointer]
                                         [pad6 _pointer]
                                         [pad7 _pointer]))

;; GDBusNodeInfo { gint ref_count; gchar *path; GDBusInterfaceInfo **interfaces; ... }
(define (node-interfaces node)
  (ptr-ref node _pointer 2))
(define (interface-at interfaces i)
  (ptr-ref interfaces _pointer i))

(define mpris-xml
  (string-append "<node>"
                 "<interface name='org.mpris.MediaPlayer2'>"
                 "<method name='Raise'/><method name='Quit'/>"
                 "<property name='CanQuit' type='b' access='read'/>"
                 "<property name='CanRaise' type='b' access='read'/>"
                 "<property name='HasTrackList' type='b' access='read'/>"
                 "<property name='Identity' type='s' access='read'/>"
                 "<property name='DesktopEntry' type='s' access='read'/>"
                 "<property name='SupportedUriSchemes' type='as' access='read'/>"
                 "<property name='SupportedMimeTypes' type='as' access='read'/>"
                 "</interface>"
                 "<interface name='org.mpris.MediaPlayer2.Player'>"
                 "<method name='Next'/><method name='Previous'/><method name='Pause'/>"
                 "<method name='PlayPause'/><method name='Stop'/><method name='Play'/>"
                 "<method name='Seek'><arg direction='in' type='x' name='Offset'/></method>"
                 "<method name='SetPosition'><arg direction='in' type='o' name='TrackId'/>"
                 "<arg direction='in' type='x' name='Position'/></method>"
                 "<method name='OpenUri'><arg direction='in' type='s' name='Uri'/></method>"
                 "<property name='PlaybackStatus' type='s' access='read'/>"
                 "<property name='Rate' type='d' access='read'/>"
                 "<property name='Metadata' type='a{sv}' access='read'/>"
                 "<property name='Volume' type='d' access='read'/>"
                 "<property name='Position' type='x' access='read'/>"
                 "<property name='MinimumRate' type='d' access='read'/>"
                 "<property name='MaximumRate' type='d' access='read'/>"
                 "<property name='CanGoNext' type='b' access='read'/>"
                 "<property name='CanGoPrevious' type='b' access='read'/>"
                 "<property name='CanPlay' type='b' access='read'/>"
                 "<property name='CanPause' type='b' access='read'/>"
                 "<property name='CanSeek' type='b' access='read'/>"
                 "<property name='CanControl' type='b' access='read'/>"
                 "<signal name='Seeked'><arg name='Position' type='x'/></signal>"
                 "</interface>"
                 "</node>"))

(define state-box (box #f)) ; canonical info hash or #f
(define handler-box (box #f))
(define conn-box (box #f))
(define owner-box (box 0))
(define root-reg-box (box 0))
(define player-reg-box (box 0))
(define err-box (box #f))
(define get-cb-count (box 0))
(define ctx-box (box #f))
(define pump-running-box (box #f))
(define pump-thread-box (box #f))
;; glaze/http.rkt shuts a fresh custodian down after every response; a pump
;; thread spawned under a request custodian dies with that request
;; (podlens#63: live dedicated context but get-callbacks stayed 0). Own a
;; process-lifetime custodian for the pump, like sql.rkt does for its pool.
(define pump-custodian (make-custodian))
(define node-box (box #f))
(define bus-name-box (box #f))
(define last-position-box (box 0.0))

(define pump-iters (box 0))

(define (start-pump!)
  (unless (or (unbox pump-running-box) (not (unbox ctx-box)))
    (set-box! pump-running-box #t)
    (set-box! pump-thread-box
              (parameterize ([current-custodian pump-custodian])
                (thread (lambda ()
                          (let loop ()
                            (when (unbox pump-running-box)
                              ;; Racket 9.0 can leave atomic mode set after
                              ;; an FFI iteration that dispatched callbacks;
                              ;; any later allocation would then raise
                              ;; internal-error (or spin without yielding).
                              ;; Outside the foreign frame here, so dropping
                              ;; atomicity may safely deschedule.
                              (when (in-atomic-mode?)
                                (end-atomic))
                              (set-box! pump-iters (add1 (unbox pump-iters)))
                              ;; When a webview pump is live it iterates our
                              ;; context (single iterator thread: a second
                              ;; Racket thread dispatching GDBus callbacks
                              ;; corrupts the scheduler under hosted WebKit).
                              (unless (external-pump?)
                                (with-handlers ([exn:fail? (lambda (e)
                                                             (fprintf (current-error-port)
                                                                      "[np-pump] exn=~a\n"
                                                                      (exn-message e)))])
                                  (g_main_context_iteration (unbox ctx-box) #f)))
                              ;; Racket 9.0 can leave atomic mode set after an
                              ;; FFI call that dispatched callbacks; a bare
                              ;; sleep then raises internal-error and kills
                              ;; the pump. Tolerate it and keep iterating.
                              (with-handlers ([exn:fail? (lambda (_) (void))])
                                (sleep 0.005))
                              (drain-commands!)
                              (loop)))))))))

(define (session-connection)
  (or (unbox conn-box)
      (and g_bus_get_sync
           (let ()
             (define err (malloc _pointer 1))
             (ptr-set! err _pointer #f)
             (define ctx (and g_main_context_new (g_main_context_new)))
             (define before
               (and g_main_context_get_thread_default (g_main_context_get_thread_default)))
             (when ctx
               (g_main_context_push_thread_default ctx))
             (define addr (getenv "DBUS_SESSION_BUS_ADDRESS"))
             (define private? (and addr g_dbus_connection_new_for_address_sync #t))
             (define c0
               (and private?
                    ;; AUTHENTICATION_CLIENT (1<<0) | MESSAGE_BUS_CONNECTION (1<<3)
                    (g_dbus_connection_new_for_address_sync addr 9 #f #f err)))
             (when (and private? (not c0))
               (with-handlers ([exn:fail? (lambda (_) (void))])
                 (define gerr (ptr-ref err _pointer))
                 (when gerr
                   (define msg (ptr-ref gerr _pointer 1))
                   (when msg
                     (fprintf (current-error-port)
                              "[np-ctx] private GError=~a\n"
                              (cast msg _pointer _string)))))
               (ptr-set! err _pointer #f))
             (define c (or c0 (g_bus_get_sync 2 #f err)))
             (when ctx
               (g_main_context_pop_thread_default ctx))
             (fprintf (current-error-port)
                      "[np-ctx] conn=~a ctx=~a default=~a thread-default=~a private=~a\n"
                      c
                      ctx
                      (and g_main_context_default (g_main_context_default))
                      before
                      (and c0 #t))
             (when (or (not c) (ptr-ref err _pointer))
               ;; Keep the GError message for carrier diagnostics: a silent
               ;; #f here once cost a full CI cycle to interpret.
               (with-handlers ([exn:fail? (lambda (_) (void))])
                 (define gerr (ptr-ref err _pointer))
                 (when gerr
                   ;; GError: guint32 domain + gint code, then gchar* message
                   ;; at byte 8 = _pointer element 1.
                   (define msg (ptr-ref gerr _pointer 1))
                   (when msg
                     (set-box! err-box (cast msg _pointer _string)))))
               (set! c #f))
             (when c
               (set-box! conn-box c)
               (when ctx
                 (set-box! ctx-box ctx)
                 (register-main-context! ctx)
                 (start-pump!)))
             c))))

;; Capability, not runtime state: library + symbols present. Whether the
;; session bus is reachable right now is reported by `diagnostics` and
;; tolerated by publish!/os-info (optional-capability degradation).
(define (supported?)
  (and gio
       g_bus_get_sync
       g_dbus_connection_register_object
       g_bus_own_name_on_connection
       g_variant_builder_init
       #t))

;; Carrier diagnostics for hosts whose verify logs must explain an inert
;; Now Playing surface (podlens#63). Backend-local, not public API.
(define (diagnostics)
  (hasheq 'gio
          (and gio #t)
          'symbols
          (and g_bus_get_sync
               g_dbus_connection_register_object
               g_bus_own_name_on_connection
               g_variant_builder_init
               #t)
          'bus-address
          (getenv "DBUS_SESSION_BUS_ADDRESS")
          'connected
          (and (unbox conn-box) #t)
          'root-reg
          (unbox root-reg-box)
          'player-reg
          (unbox player-reg-box)
          'owner
          (unbox owner-box)
          'name
          (unbox bus-name-box)
          'unique-name
          (and (unbox conn-box) (g_dbus_connection_get_unique_name (unbox conn-box)))
          'error
          (unbox err-box)
          'get-callbacks
          (unbox get-cb-count)
          'ctx
          (format "~a" (unbox ctx-box))
          'ctx-is-default
          (and g_main_context_default (equal? (unbox ctx-box) (g_main_context_default)))
          'pump-alive
          (and (unbox pump-thread-box) (thread-running? (unbox pump-thread-box)))
          'pump-iters
          (unbox pump-iters)
          'get-title
          (hash-ref (or (unbox state-box) (hash)) 'title "")
          'get-status
          (if (and (unbox state-box) (hash-ref (unbox state-box) 'playing #f)) "Playing" "Stopped")))

;; ---- GVariant helpers ----------------------------------------------------

(define (new-builder [type "a{sv}"])
  ;; GVariantBuilder union: largest member gpointer x[16]; over-allocate
  ;; with pointer alignment (a byte-aligned buffer trips valid_builder).
  (define b (malloc _pointer 32))
  (memset b 0 256)
  (g_variant_builder_init b type)
  b)

(define (builder-add! b key variant)
  (g_variant_builder_add_sv b "{sv}" key (g_variant_ref_sink variant)))

(define (strv-1 s)
  (define cstr (malloc _byte (add1 (string-length s))))
  (memcpy cstr (string->bytes/utf-8 s) (string-length s))
  (ptr-set! cstr _byte (string-length s) 0)
  (define arr (malloc _pointer 2))
  (ptr-set! arr _pointer 0 cstr)
  (ptr-set! arr _pointer 1 #f)
  (g_variant_new_strv arr 1))

(define (metadata-variant info)
  (define b (new-builder))
  (builder-add! b "mpris:trackid" (g_variant_new_string "/org/mpris/MediaPlayer2/glaze"))
  (builder-add! b
                "mpris:length"
                (g_variant_new_int64 (inexact->exact (round (* 1e6 (hash-ref info 'duration 0.0))))))
  (builder-add! b "xesam:title" (g_variant_new_string (hash-ref info 'title "")))
  (builder-add! b "xesam:album" (g_variant_new_string (hash-ref info 'album "")))
  (builder-add! b
                "xesam:artist"
                (if (non-empty-string? (hash-ref info 'artist ""))
                    (strv-1 (hash-ref info 'artist ""))
                    (g_variant_new_strv #f 0)))
  (g_variant_ref_sink (g_variant_new_dict "a{sv}" b)))

(define (playback-status info)
  (cond
    [(not info) "Stopped"]
    [(hash-ref info 'playing #f) "Playing"]
    [else "Paused"]))

(define (position-usecs info)
  (inexact->exact (round (* 1e6 (hash-ref info 'position 0.0)))))

;; ---- callbacks -----------------------------------------------------------
;; GDBus invokes vtable callbacks inside a foreign stack frame. Any Racket
;; allocation / break check there can deschedule and longjmp out of that
;; frame: Racket 9.0 raises internal-error, 9.3 corrupts the heap (podlens
;; verify core-dumped once callbacks actually dispatched). Even _string FFI
;; arguments allocate in the wrapper. So the callbacks below are pure FFI +
;; fixnum straight-line code: g_strcmp0 against static C strings, a
;; precomputed variant table, and a command ring. All string conversion and
;; handler dispatch happens on the pump thread, outside the foreign frame.

(defgio g_variant_ref (_fun _GVariant -> _GVariant))
(defgio g_variant_unref (_fun _GVariant -> _void))
(defglib g_strcmp0 (_fun _pointer _pointer -> _int))

(define (cstr s)
  (define n (string-length s))
  (define b (malloc _byte (add1 n)))
  (for ([i (in-range n)])
    (ptr-set! b _byte i (char->integer (string-ref s i))))
  (ptr-set! b _byte n 0)
  b)

(define prop-names
  '("PlaybackStatus" "Metadata"
                     "Position"
                     "Rate"
                     "Volume"
                     "MinimumRate"
                     "MaximumRate"
                     "CanGoNext"
                     "CanGoPrevious"
                     "CanPlay"
                     "CanPause"
                     "CanSeek"
                     "CanControl"
                     "CanQuit"
                     "CanRaise"
                     "HasTrackList"
                     "Identity"
                     "DesktopEntry"
                     "SupportedUriSchemes"
                     "SupportedMimeTypes"))
(define prop-cvec (list->vector (map cstr prop-names)))
(define c-root-iface (cstr "org.mpris.MediaPlayer2"))
(define prop-table (malloc _pointer 20))
(for ([i (in-range 20)])
  (ptr-set! prop-table _pointer i #f))

(define method-names '("Play" "Pause" "Stop" "PlayPause" "Next" "Previous" "Seek" "SetPosition"))
(define method-cvec (list->vector (map cstr method-names)))
(define cmd-ring (malloc _pointer 16))
(define cmd-idx-ring (malloc _int64 8))
(define cmd-head (box 0))
(define cmd-tail (box 0))

(define (prop-ref i)
  (define v (ptr-ref prop-table _pointer i))
  (if v
      (g_variant_ref v)
      (g_variant_new_string "")))

;; Racket's FFI trampoline can leave atomic mode set at the callback-exit
;; safe point; a scheduler swap there dies ("terminated in atomic mode!",
;; glaze#157). Run callback bodies nonatomic whenever entered atomic.
(define (in-out-atomic thunk)
  (if (in-atomic-mode?)
      (call-as-nonatomic thunk)
      (thunk)))

(define get-property-cb
  (cast (lambda (conn sender path iface name err user)
          (in-out-atomic (lambda ()
                           (set-box! get-cb-count (add1 (unbox get-cb-count)))
                           (if (zero? (g_strcmp0 iface c-root-iface))
                               (cond
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 13))) (prop-ref 13)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 14))) (prop-ref 14)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 15))) (prop-ref 15)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 16))) (prop-ref 16)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 17))) (prop-ref 17)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 18))) (prop-ref 18)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 19))) (prop-ref 19)]
                                 [else (g_variant_new_string "")])
                               (cond
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 0))) (prop-ref 0)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 1))) (prop-ref 1)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 2))) (prop-ref 2)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 3))) (prop-ref 3)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 4))) (prop-ref 4)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 5))) (prop-ref 5)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 6))) (prop-ref 6)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 7))) (prop-ref 7)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 8))) (prop-ref 8)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 9))) (prop-ref 9)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 10))) (prop-ref 10)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 11))) (prop-ref 11)]
                                 [(zero? (g_strcmp0 name (vector-ref prop-cvec 12))) (prop-ref 12)]
                                 [else (g_variant_new_string "")])))))
        (_fun _pointer _pointer _pointer _pointer _pointer _pointer _pointer -> _pointer)
        _fpointer))

(define method-call-cb
  (cast (lambda (conn sender path iface method parameters invocation user)
          (in-out-atomic (lambda ()
                           (define midx
                             (cond
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 0))) 0]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 1))) 1]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 2))) 2]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 3))) 3]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 4))) 4]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 5))) 5]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 6))) 6]
                               [(zero? (g_strcmp0 method (vector-ref method-cvec 7))) 7]
                               [else -1]))
                           (when (>= midx 0)
                             (define i (unbox cmd-head))
                             (unless (= (modulo (add1 i) 8) (unbox cmd-tail))
                               (ptr-set! cmd-ring _pointer (* 2 i) invocation)
                               (ptr-set! cmd-ring _pointer (+ (* 2 i) 1) (g_variant_ref parameters))
                               (ptr-set! cmd-idx-ring _int64 i midx)
                               (set-box! cmd-head (modulo (add1 i) 8)))))))
        (_fun _pointer _pointer _pointer _pointer _pointer _pointer _pointer _pointer -> _void)
        _fpointer))

(define set-property-cb
  (cast (lambda (conn sender path iface name value err user) (in-out-atomic (lambda () #f)))
        (_fun _pointer _pointer _pointer _pointer _pointer _pointer _pointer _pointer -> _bool)
        _fpointer))

(define (drain-commands!)
  (let loop ()
    (define t (unbox cmd-tail))
    (unless (= t (unbox cmd-head))
      (define inv (ptr-ref cmd-ring _pointer (* 2 t)))
      (define par (ptr-ref cmd-ring _pointer (+ (* 2 t) 1)))
      (define midx (ptr-ref cmd-idx-ring _int64 t))
      (set-box! cmd-tail (modulo (add1 t) 8))
      (with-handlers
          ([exn:fail?
            (lambda (e)
              (g_dbus_method_invocation_return_error inv 0 0 "glaze now-playing handler failed"))])
        (dispatch-command! (list-ref method-names midx) par)
        (g_dbus_method_invocation_return_value inv #f))
      (g_variant_unref par)
      (loop))))

(define (dispatch-command! name parameters)
  (define handler (unbox handler-box))
  (when handler
    (case name
      [("Play") (handler 'play #f)]
      [("Pause") (handler 'pause #f)]
      [("Stop") (handler 'stop #f)]
      [("PlayPause") (handler 'toggle #f)]
      [("Next") (handler 'next #f)]
      [("Previous") (handler 'previous #f)]
      [("Seek")
       (handler 'seek-by (/ (g_variant_get_int64 (g_variant_get_child_value parameters 0)) 1e6))]
      [("SetPosition")
       (handler 'seek-to (/ (g_variant_get_int64 (g_variant_get_child_value parameters 1)) 1e6))]
      [else (void)])))

(define (store-prop! i v)
  (define old (ptr-ref prop-table _pointer i))
  (when old
    (g_variant_unref old))
  (ptr-set! prop-table _pointer i (g_variant_ref_sink v)))

;; Precompute every property variant on the publishing (request) thread so
;; the foreign-frame callback only refs a ready pointer.
(define (build-props! info)
  (store-prop! 0 (g_variant_new_string (playback-status info)))
  (store-prop! 1 (metadata-variant (or info (hash 'title "" 'duration 0.0))))
  (store-prop! 2
               (g_variant_new_int64 (if info
                                        (position-usecs info)
                                        0)))
  (for ([i (in-range 3 7)])
    (store-prop! i (g_variant_new_double 1.0)))
  (for ([i (in-range 7 13)])
    (store-prop! i (g_variant_new_boolean #t)))
  (for ([i (in-range 13 16)])
    (store-prop! i (g_variant_new_boolean #f)))
  (store-prop! 16
               (g_variant_new_string (if info
                                         (hash-ref info 'identifier "glaze")
                                         "glaze")))
  (store-prop! 17 (g_variant_new_string ""))
  (store-prop! 18 (g_variant_new_strv #f 0))
  (store-prop! 19 (g_variant_new_strv #f 0)))

(define vtable
  (make-GDBusInterfaceVTable method-call-cb get-property-cb set-property-cb #f #f #f #f #f #f #f #f))

;; ---- publication ---------------------------------------------------------

(define (sanitize-id id)
  (string-join (filter non-empty-string? (regexp-split #px"[^A-Za-z0-9_]+" id)) "_"))

(define (ensure-registered! info)
  (define conn (session-connection))
  (unless conn
    (error 'now-playing-linux "no session bus"))
  (unless (unbox node-box)
    (define err (malloc _pointer 1))
    (ptr-set! err _pointer #f)
    (define node (g_dbus_node_info_new_for_xml mpris-xml err))
    (unless node
      (error 'now-playing-linux "MPRIS introspection XML rejected"))
    (set-box! node-box node))
  (define interfaces (node-interfaces (unbox node-box)))
  (when (zero? (unbox root-reg-box))
    (define err (malloc _pointer 1))
    (ptr-set! err _pointer #f)
    (set-box! root-reg-box
              (g_dbus_connection_register_object conn
                                                 "/org/mpris/MediaPlayer2"
                                                 (interface-at interfaces 0)
                                                 vtable
                                                 #f
                                                 #f
                                                 err)))
  (when (zero? (unbox player-reg-box))
    (define err (malloc _pointer 1))
    (ptr-set! err _pointer #f)
    (set-box! player-reg-box
              (g_dbus_connection_register_object conn
                                                 "/org/mpris/MediaPlayer2"
                                                 (interface-at interfaces 1)
                                                 vtable
                                                 #f
                                                 #f
                                                 err)))
  (when (zero? (unbox owner-box))
    (define name
      (string-append "org.mpris.MediaPlayer2." (sanitize-id (hash-ref info 'identifier "glaze"))))
    (set-box! bus-name-box name)
    (set-box! owner-box (g_bus_own_name_on_connection conn name 0 #f #f #f #f #f))))

(define (emit-properties! info)
  (define conn (unbox conn-box))
  (when conn
    (define b (new-builder))
    (builder-add! b "Metadata" (metadata-variant (or info (hash 'title "" 'duration 0.0))))
    (builder-add! b "PlaybackStatus" (g_variant_new_string (playback-status info)))
    ;; g_variant_new's array slots consume GVariantBuilder pointers, not
    ;; built values: hand over the builders and let it end them.
    (define empty (new-builder "as"))
    (define params
      (g_variant_ref_sink (g_variant_new_props "(sa{sv}as)" "org.mpris.MediaPlayer2.Player" b empty)))
    (define err (malloc _pointer 1))
    (ptr-set! err _pointer #f)
    (g_dbus_connection_emit_signal conn
                                   #f
                                   "/org/mpris/MediaPlayer2"
                                   "org.freedesktop.DBus.Properties"
                                   "PropertiesChanged"
                                   params
                                   err)
    (define pos
      (if info
          (hash-ref info 'position 0.0)
          0.0))
    (when (and info (> (abs (- pos (unbox last-position-box))) 2.0))
      (define err2 (malloc _pointer 1))
      (ptr-set! err2 _pointer #f)
      (g_dbus_connection_emit_signal conn
                                     #f
                                     "/org/mpris/MediaPlayer2"
                                     "org.mpris.MediaPlayer2.Player"
                                     "Seeked"
                                     (g_variant_ref_sink (g_variant_new_x "(x)"
                                                                          (position-usecs info)))
                                     err2))
    (set-box! last-position-box pos)))

(define (publish! info handler)
  (set-box! handler-box handler)
  (set-box! state-box info)
  (with-handlers ([exn:fail? (lambda (e) (set-box! err-box (exn-message e)))])
    (cond
      [info
       (build-props! info)
       (ensure-registered! info)
       (emit-properties! info)]
      [else
       (build-props! #f)
       (set-box! last-position-box 0.0)
       (emit-properties! #f)])))

(define (set-handler! proc)
  (set-box! handler-box proc))

;; OS-surface readback: the host owns the MPRIS object, so its state box IS
;; the published state. In-process self-Get over the owning connection proved
;; unreliable under Racket's atomic FFI mode (the async finish idle never
;; dispatches); real bus-surface evidence is collected by an external client
;; (dbus-send) in glaze-test/now-playing-test.rkt and in product verify runs.
(define (os-info)
  (and (not (zero? (unbox owner-box)))
       (let ()
         (define info (unbox state-box))
         (hash 'title
               (if info
                   (hash-ref info 'title "")
                   "")
               'playing
               (and info (hash-ref info 'playing #f) #t)
               'position
               (if info
                   (hash-ref info 'position 0.0)
                   0.0)
               'bus-name
               (unbox bus-name-box)))))

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
         glaze/ffi-discovery
         racket/string)

(provide supported?
         publish!
         os-info
         set-handler!
         diagnostics)

(define gio (ffi-lib* "libgio-2.0" '("0" "")))

(define-ffi-definer defgio gio)

(define _GVariant _pointer)
(define _GDBusConnection _pointer)

(defgio g_bus_get_sync (_fun _int _pointer _pointer -> _GDBusConnection))
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
(defgio g_variant_new_strv (_fun _pointer _int -> _GVariant))
(defgio g_variant_new_x (_fun _string _int64 -> _GVariant) #:c-id g_variant_new)
(defgio g_variant_new_props
        (_fun _string _string _GVariant _GVariant -> _GVariant)
        #:c-id g_variant_new)
(defgio g_variant_new_ss (_fun _string _string _string -> _GVariant) #:c-id g_variant_new)
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
(defgio g_variant_get_child_value (_fun _GVariant _int -> _GVariant))
(defgio g_variant_lookup_value (_fun _GVariant _string _pointer -> _GVariant))

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
(define node-box (box #f))
(define bus-name-box (box #f))
(define last-position-box (box 0.0))

(define (session-connection)
  (or (unbox conn-box)
      (and g_bus_get_sync
           (let ()
             (define err (malloc _pointer 1))
             (ptr-set! err _pointer #f)
             (define c (g_bus_get_sync 2 #f err))
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
               (set-box! conn-box c))
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
          'error
          (unbox err-box)
          'get-callbacks
          (unbox get-cb-count)
          'get-title
          (bus-get "Metadata")
          'get-status
          (bus-get "PlaybackStatus")))

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
  (g_variant_ref_sink (g_variant_new_dict "(a{sv})" b)))

(define (playback-status info)
  (cond
    [(not info) "Stopped"]
    [(hash-ref info 'playing #f) "Playing"]
    [else "Paused"]))

(define (position-usecs info)
  (inexact->exact (round (* 1e6 (hash-ref info 'position 0.0)))))

;; ---- callbacks -----------------------------------------------------------

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

(define method-call-cb
  (cast
   (lambda (conn sender path iface method parameters invocation user)
     (fprintf (current-error-port) "[np-cb] method enter ~a.~a\n" iface method)
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (fprintf (current-error-port) "[np-cb] method error ~a\n" (exn-message e))
                        (g_dbus_method_invocation_return_error invocation
                                                               0
                                                               0
                                                               "glaze now-playing handler failed"))])
       (dispatch-command! method parameters)
       (g_dbus_method_invocation_return_value invocation #f))
     (fprintf (current-error-port) "[np-cb] method exit ~a\n" method))
   (_fun _GDBusConnection _string _string _string _string _GVariant _pointer _pointer -> _void)
   _fpointer))

(define (root-property name)
  (define info (unbox state-box))
  (case name
    [("CanQuit" "CanRaise" "HasTrackList") (g_variant_new_boolean #f)]
    [("Identity")
     (g_variant_new_string (if info
                               (hash-ref info 'identifier "glaze")
                               "glaze"))]
    [("DesktopEntry") (g_variant_new_string "")]
    [("SupportedUriSchemes" "SupportedMimeTypes") (g_variant_new_strv #f 0)]
    [else #f]))

(define (player-property name)
  (define info (unbox state-box))
  (case name
    [("PlaybackStatus") (g_variant_new_string (playback-status info))]
    [("Metadata") (metadata-variant (or info (hash 'title "" 'duration 0.0)))]
    [("Position")
     (g_variant_new_int64 (if info
                              (position-usecs info)
                              0))]
    [("Rate" "Volume" "MinimumRate" "MaximumRate") (g_variant_new_double 1.0)]
    [("CanGoNext" "CanGoPrevious" "CanPlay" "CanPause" "CanSeek" "CanControl")
     (g_variant_new_boolean #t)]
    [else #f]))

(define get-property-cb
  (cast (lambda (conn sender path iface name err user)
          (fprintf (current-error-port) "[np-cb] get enter ~a.~a\n" iface name)
          (define v
            (with-handlers ([exn:fail?
                             (lambda (e)
                               (fprintf (current-error-port) "[np-cb] get error ~a\n" (exn-message e))
                               #f)])
              (if (equal? iface "org.mpris.MediaPlayer2")
                  (root-property name)
                  (player-property name))))
          (fprintf (current-error-port) "[np-cb] get exit ~a v=~a\n" name (and v #t))
          (or v (g_variant_new_string "")))
        (_fun _GDBusConnection _string _string _string _string _pointer _pointer -> _GVariant)
        _fpointer))

(define set-property-cb
  (cast (lambda (conn sender path iface name value err user) #f)
        (_fun _GDBusConnection _string _string _string _string _GVariant _pointer _pointer -> _bool)
        _fpointer))

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
       (ensure-registered! info)
       (emit-properties! info)]
      [else
       (set-box! last-position-box 0.0)
       (emit-properties! #f)])))

(define (set-handler! proc)
  (set-box! handler-box proc))

;; Read our own published properties back over the bus: acceptance evidence
;; that the OS surface carries the state, not just host memory.
;; The Get reply is produced by our own vtable callback, which GDBus
;; dispatches on the main context: a same-thread call_sync would deadlock
;; against it, so issue an async call and pump the default main context
;; until the finish callback lands.
(define glib (ffi-lib* "libglib-2.0" '("0" "")))
(define-ffi-definer defglib glib)
(defglib g_main_context_iteration (_fun _pointer _bool -> _bool))
(define (pump-context!)
  (when g_main_context_iteration
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (g_main_context_iteration #f #f))))

(defgio g_dbus_connection_call
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
              _void))
(defgio g_dbus_connection_call_finish (_fun _GDBusConnection _pointer _pointer -> _GVariant))

(define (bus-get property)
  (define conn (unbox conn-box))
  (define name (unbox bus-name-box))
  (and
   conn
   name
   (let ()
     (define reply-box (box 'pending))
     (define cb
       (cast (lambda (source res user)
               (fprintf (current-error-port) "[np-cb] finish enter\n")
               (define err (malloc _pointer 1))
               (ptr-set! err _pointer #f)
               (set-box! get-cb-count (add1 (unbox get-cb-count)))
               (set-box! reply-box (g_dbus_connection_call_finish source res err))
               (fprintf (current-error-port) "[np-cb] finish exit v=~a\n" (and (unbox reply-box) #t)))
             (_fun _pointer _pointer _pointer -> _void)
             _fpointer))
     (define args
       (g_variant_ref_sink (g_variant_new_ss "(ss)" "org.mpris.MediaPlayer2.Player" property)))
     (g_dbus_connection_call conn
                             name
                             "/org/mpris/MediaPlayer2"
                             "org.freedesktop.DBus.Properties"
                             "Get"
                             args
                             #f
                             0
                             2000
                             cb
                             #f)
     (define deadline (+ (current-inexact-milliseconds) 3000))
     (let loop ()
       (cond
         [(not (eq? (unbox reply-box) 'pending)) (parse-reply (unbox reply-box) property)]
         [(< (current-inexact-milliseconds) deadline)
          ;; No sleep: bus-get may run inside a GDBus callback (atomic
          ;; mode), where descheduling is an internal error.
          (pump-context!)
          (loop)]
         [else #f])))))

(define (parse-reply reply property)
  (and reply
       (let ()
         (define inner (g_variant_get_child_value reply 0))
         (case property
           [("Metadata")
            (define title-v (g_variant_lookup_value inner "xesam:title" #f))
            (define title (and title-v (g_variant_get_string title-v #f)))
            (or title "")]
           [("PlaybackStatus") (g_variant_get_string inner #f)]
           [("Position") (/ (g_variant_get_int64 inner) 1e6)]
           [else #f]))))

(define (os-info)
  (and (not (zero? (unbox owner-box)))
       (let ()
         (define title (bus-get "Metadata"))
         (define status (bus-get "PlaybackStatus"))
         (define pos (bus-get "Position"))
         (and title
              status
              (hash 'title
                    title
                    'playing
                    (equal? status "Playing")
                    'position
                    (or pos 0.0)
                    'bus-name
                    (unbox bus-name-box))))))

#lang racket/base

;; glaze#153 — host-owned OS Now Playing capability contract.
;;
;; Windows: inert stub (web MediaSession owns SMTC there; verified by the
;; product acceptance matrices). macOS: public MediaPlayer.framework
;; publication + readback. Linux: host-owned MPRIS over the session bus,
;; including a real bus readback and command dispatch round-trip.

(require glaze/now-playing
         rackunit
         racket/system
         racket/string
         ffi/unsafe)

;; GDBus dispatches method calls and name callbacks on the main context;
;; a bare sleep loop never pumps it. Pump the default context so the
;; round-trip below is real bus evidence on headless CI.
(define glib-iterate
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (get-ffi-obj 'g_main_context_iteration
                 (ffi-lib "libglib-2.0" '("0" ""))
                 (_fun _pointer _bool -> _bool))))
(define (pump!)
  (when glib-iterate
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (glib-iterate #f #f))))

;; On headless Linux CI there is no session bus. Bootstrap a private one
;; before the first backend call so the MPRIS round-trip below is real bus
;; evidence, not a degraded-path pass. Failure to bootstrap falls back to
;; the unsupported-path assertions.
(define private-bus-control #f)
(when (eq? (system-type 'os) 'unix)
  (unless (getenv "DBUS_SESSION_BUS_ADDRESS")
    (with-handlers ([exn:fail? (lambda (e)
                                 (printf "[now-playing-diag] bus bootstrap error: ~a\n"
                                         (exn-message e)))])
      ;; Racket 9.x process returns one list value; 8.x returned five.
      (define parts
        (call-with-values (lambda () (process "dbus-daemon --session --nofork --print-address=1"))
                          (lambda vs
                            (if (and (= 1 (length vs)) (list? (car vs)))
                                (car vs)
                                vs))))
      (define out (list-ref parts 0))
      (define control (list-ref parts 4))
      (define address (read-line out))
      (printf "[now-playing-diag] bus bootstrap address=~s\n" address)
      (when (and (string? address) (non-empty-string? address))
        (putenv "DBUS_SESSION_BUS_ADDRESS" address)
        (set! private-bus-control control)))))

;; First backend load happens here, before any dispatcher call can cache
;; a silent partial instantiation: print the real exception if any.
(when (eq? (system-type 'os) 'unix)
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "[now-playing-diag] first linux load error: ~a\n"
                                       (exn-message e)))])
    (dynamic-require 'glaze/now-playing/now-playing-linux 'supported?))
  (with-handlers ([exn:fail? (lambda (e)
                               (printf "[now-playing-diag] gio probe error: ~a\n" (exn-message e)))])
    (define ffi-lib* (dynamic-require 'glaze/ffi-discovery 'ffi-lib*))
    (define ffi-lib-reason (dynamic-require 'glaze/ffi-discovery 'ffi-lib-reason))
    (printf "[now-playing-diag] gio-lib=~a reason=~a\n"
            (ffi-lib* "libgio-2.0" '("0" ""))
            (ffi-lib-reason))))

(define (canonical)
  (hash 'identifier
        "site.glaze.test"
        'title
        "Glaze Now Playing Test"
        'artist
        "Glaze"
        'album
        "Capability"
        'duration
        12.5
        'position
        3.0
        'playing
        #t))

(test-case "supported? is a boolean on every platform"
  (check-pred boolean? (now-playing-supported?)))

(test-case "non-hash info violates the public contract"
  (check-exn exn:fail? (lambda () (now-playing-set! "not a hash"))))

(test-case "normalize coerces unknown/invalid fields instead of raising"
  (now-playing-set! (hash 'title 42 'duration -1 'playing 'yes))
  (define info (now-playing-info))
  (check-equal? (hash-ref info 'title) "")
  (check-equal? (hash-ref info 'duration) -1.0)
  (check-equal? (hash-ref info 'playing) #t)
  (check-equal? (hash-ref info 'identifier) "glaze")
  (now-playing-clear!)
  (check-false (now-playing-info)))

(test-case "set!/clear!/handler/os-info never raise on any platform"
  (check-equal? (now-playing-set-command-handler! (lambda (cmd arg) (void))) (void))
  (now-playing-set! (canonical))
  (now-playing-clear!)
  (define os (now-playing-os-info))
  (check-true (or (hash? os) (not os))))

(case (system-type 'os)
  [(windows)
   (test-case "windows stub is inert: web MediaSession owns SMTC"
     (check-false (now-playing-supported?))
     (check-false (now-playing-os-info)))]
  [(macosx)
   (test-case "macos backend module loads (no silent stub fallback)"
     (with-handlers ([exn:fail? (lambda (e)
                                  (printf "[now-playing-diag] macos load error: ~a\n"
                                          (exn-message e)))])
       (dynamic-require 'glaze/now-playing/now-playing-macos #f))
     (check-not-exn (lambda () (dynamic-require 'glaze/now-playing/now-playing-macos #f))))
   (test-case "macos publishes through MPNowPlayingInfoCenter and reads back"
     ;; Diagnostic evidence when the capability reports unsupported: which
     ;; library or class lookup failed, straight from the platform APIs.
     (unless (now-playing-supported?)
       (define ffi-lib* (dynamic-require 'glaze/ffi-discovery 'ffi-lib*))
       (define ffi-lib-reason (dynamic-require 'glaze/ffi-discovery 'ffi-lib-reason))
       (define objc-get-class (dynamic-require 'ffi/unsafe/objc 'objc_lookUpClass))
       (define mp (ffi-lib* "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer" '(#f)))
       (printf "[now-playing-diag] mp-lib=~a reason=~a\n" mp (ffi-lib-reason))
       (for ([n (in-list '("MPNowPlayingInfoCenter" "MPRemoteCommandCenter"
                                                    "NSMutableDictionary"
                                                    "NSNumber"
                                                    "NSString"))])
         (printf "[now-playing-diag] ~a=~a\n"
                 n
                 (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
                   (objc-get-class n)))))
     (check-true (now-playing-supported?))
     (now-playing-set! (canonical))
     (define os (now-playing-os-info))
     (unless (hash? os)
       (printf "[now-playing-diag] macos readback os-info=#f diag=~s\n"
               (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
                 ((dynamic-require 'glaze/now-playing/now-playing-macos 'diagnostics)))))
     (check-pred hash? os)
     (check-equal? (hash-ref os 'title) "Glaze Now Playing Test")
     (check-equal? (hash-ref os 'playing) #t)
     (check-= (hash-ref os 'position) 3.0 0.01)
     (now-playing-set! (hash-set (canonical) 'playing #f))
     (check-equal? (hash-ref (now-playing-os-info) 'playing) #f)
     (now-playing-clear!)
     (check-false (now-playing-os-info)))]
  [(unix)
   (test-case "linux backend module loads (no silent stub fallback)"
     (with-handlers ([exn:fail? (lambda (e)
                                  (printf "[now-playing-diag] linux load error: ~a\n"
                                          (exn-message e)))])
       (dynamic-require 'glaze/now-playing/now-playing-linux #f))
     (check-not-exn (lambda () (dynamic-require 'glaze/now-playing/now-playing-linux #f))))
   (cond
     [(now-playing-supported?)
      (test-case "linux owns an MPRIS name and reads properties back over the bus"
        (define received '())
        (now-playing-set-command-handler! (lambda (cmd arg)
                                            (set! received (cons (cons cmd arg) received))))
        (now-playing-set! (canonical))
        (define os
          (let loop ([n 0])
            (define v (now-playing-os-info))
            (cond
              [(hash? v) v]
              [(< n 40)
               (pump!)
               (sleep 0.05)
               (loop (add1 n))]
              [else v])))
        (unless (hash? os)
          (printf "[now-playing-diag] linux round-trip os-info=#f diag=~s\n"
                  (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
                    ((dynamic-require 'glaze/now-playing/now-playing-linux 'diagnostics)))))
        (check-pred hash? os)
        (check-equal? (hash-ref os 'title) "Glaze Now Playing Test")
        (check-equal? (hash-ref os 'playing) #t)
        (check-= (hash-ref os 'position) 3.0 0.01)
        (check-true (string-prefix? (hash-ref os 'bus-name) "org.mpris.MediaPlayer2."))
        ;; Command round-trip: Pause arrives through GDBus on the main context.
        (define bus-name (hash-ref os 'bus-name))
        (system
         (format
          "dbus-send --session --print-reply --dest=~a /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Pause"
          bus-name))
        (define deadline (+ (current-inexact-milliseconds) 5000))
        (let loop ()
          (when (and (null? received) (< (current-inexact-milliseconds) deadline))
            (pump!)
            (sleep 0.05)
            (loop)))
        (check-true (and (pair? received) (equal? (car received) '(pause . #f))))
        (now-playing-clear!)
        (define os2
          (let loop ([n 0])
            (define v (now-playing-os-info))
            (cond
              [(and (hash? v) (not (hash-ref v 'playing))) v]
              [(< n 40)
               (pump!)
               (sleep 0.05)
               (loop (add1 n))]
              [else v])))
        (check-equal? (hash-ref os2 'playing) #f))]
     [else
      (test-case "linux without a session bus degrades to unsupported"
        (check-false (now-playing-os-info)))])])

(when private-bus-control
  (private-bus-control 'kill))

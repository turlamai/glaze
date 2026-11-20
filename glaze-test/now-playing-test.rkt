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
         racket/string)

;; On headless Linux CI there is no session bus. Bootstrap a private one
;; before the first backend call so the MPRIS round-trip below is real bus
;; evidence, not a degraded-path pass. Failure to bootstrap falls back to
;; the unsupported-path assertions.
(define private-bus-control #f)
(when (eq? (system-type 'os) 'unix)
  (unless (getenv "DBUS_SESSION_BUS_ADDRESS")
    (with-handlers ([exn:fail? (lambda (_) (void))])
      (define-values (out in pid err control)
        (process "dbus-daemon --session --nofork --print-address=1"))
      (define address (read-line out))
      (when (and (string? address) (non-empty-string? address))
        (putenv "DBUS_SESSION_BUS_ADDRESS" address)
        (set! private-bus-control control)))))

(define (canonical)
  (hash 'identifier "site.glaze.test"
        'title "Glaze Now Playing Test"
        'artist "Glaze"
        'album "Capability"
        'duration 12.5
        'position 3.0
        'playing #t))

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
     (check-not-exn (lambda () (dynamic-require 'glaze/now-playing/now-playing-macos #f))))
   (test-case "macos publishes through MPNowPlayingInfoCenter and reads back"
     (check-true (now-playing-supported?))
     (now-playing-set! (canonical))
     (define os (now-playing-os-info))
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
     (check-not-exn (lambda () (dynamic-require 'glaze/now-playing/now-playing-linux #f))))
   (cond
     [(now-playing-supported?)
      (test-case "linux owns an MPRIS name and reads properties back over the bus"
        (define received '())
        (now-playing-set-command-handler!
         (lambda (cmd arg) (set! received (cons (cons cmd arg) received))))
        (now-playing-set! (canonical))
        (define os (now-playing-os-info))
        (check-pred hash? os)
        (check-equal? (hash-ref os 'title) "Glaze Now Playing Test")
        (check-equal? (hash-ref os 'playing) #t)
        (check-= (hash-ref os 'position) 3.0 0.01)
        (check-true (string-prefix? (hash-ref os 'bus-name) "org.mpris.MediaPlayer2."))
        ;; Command round-trip: Pause arrives through GDBus on the main context.
        (define bus-name (hash-ref os 'bus-name))
        (system (format "dbus-send --session --print-reply --dest=~a /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player.Pause"
                        bus-name))
        (define deadline (+ (current-inexact-milliseconds) 5000))
        (let loop ()
          (when (and (null? received) (< (current-inexact-milliseconds) deadline))
            (sleep 0.05)
            (loop)))
        (check-true (and (pair? received) (equal? (car received) '(pause . #f))))
        (now-playing-clear!)
        (check-equal? (hash-ref (now-playing-os-info) 'playing) #f))]
     [else
      (test-case "linux without a session bus degrades to unsupported"
        (check-false (now-playing-os-info)))])])

(when private-bus-control
  (private-bus-control 'kill))
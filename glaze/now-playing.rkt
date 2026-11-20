#lang racket/base

;; Public OS Now Playing API (glaze#153). Host-owned publication so products
;; do not depend on the web engine's MediaSession bridge (WebKitGTK's MPRIS
;; bridge is unreliable on headless CI and on real desktops, WebKit bug
;; 279362; macOS private MediaRemote drifts across releases).
;;
;; Optional capability, tray-style: a missing platform backend degrades to
;; an inert stub (`now-playing-supported?` -> #f), never a startup crash.
;;
;;   (now-playing-set! (hash 'title "..." 'artist "..." 'playing #t
;;                           'duration 123.0 'position 4.0
;;                           'identifier "site.jrtx.podlens"))
;;   (now-playing-set-command-handler! (lambda (cmd arg) ...))
;;   (now-playing-clear!)
;;
;; `now-playing-info` is the host state; `now-playing-os-info` reads the OS
;; surface back where the platform allows it (macOS MPNowPlayingInfoCenter,
;; Linux own MPRIS properties) for acceptance evidence.
;;
;; Backends export: supported? publish! os-info set-handler!
;;   'macosx -> now-playing/now-playing-macos (MediaPlayer.framework)
;;   'unix   -> now-playing/now-playing-linux (GIO/GDBus MPRIS)
;;   else    -> now-playing/now-playing-stub  (Windows: WebView2 SMTC bridge
;;              remains the verified path; host SMTC may follow later)

(require racket/contract)

(provide (contract-out
          [now-playing-supported? (-> boolean?)]
          [now-playing-set! (-> hash? any)]
          [now-playing-clear! (-> any)]
          [now-playing-info (-> (or/c hash? #f))]
          [now-playing-os-info (-> (or/c hash? #f))]
          [now-playing-set-command-handler! (-> (or/c procedure? #f) any)]))

(define info-box (box #f))
(define handler-box (box #f))

(define (backend-module-path)
  (case (system-type 'os)
    [(macosx) 'glaze/now-playing/now-playing-macos]
    [(unix) 'glaze/now-playing/now-playing-linux]
    [else 'glaze/now-playing/now-playing-stub]))

(define backend-procs #f)
(define (load-backend!)
  (unless backend-procs
    (define tbl (make-hash))
    (define mod
      (with-handlers ([exn:fail? (lambda (_) 'glaze/now-playing/now-playing-stub)])
        (backend-module-path)))
    (for ([name (in-list '(supported? publish! os-info set-handler!))])
      (hash-set! tbl name
                 (with-handlers ([exn:fail? (lambda (_) #f)])
                   (dynamic-require mod name))))
    (set! backend-procs tbl))
  backend-procs)

(define (backend-proc name)
  (hash-ref (load-backend!) name #f))

(define (call-backend name . args)
  (define proc (backend-proc name))
  (if proc
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (apply proc args))
      #f))

;; Normalize product input into the canonical host state. Unknown keys are
;; dropped so backends never see surprises; numbers are coerced once here.
(define (normalize-info raw)
  (define (num key default)
    (define v (hash-ref raw key default))
    (if (real? v) (exact->inexact v) default))
  (define (str key default)
    (define v (hash-ref raw key default))
    (if (string? v) v default))
  (hash 'title (str 'title "")
        'artist (str 'artist "")
        'album (str 'album "")
        'duration (num 'duration 0.0)
        'position (num 'position 0.0)
        'playing (and (hash-ref raw 'playing #f) #t)
        'identifier (str 'identifier "glaze")
        'artwork-url (str 'artwork-url "")))

(define (now-playing-supported?)
  (and (call-backend 'supported?) #t))

(define (now-playing-set! raw)
  (define info (normalize-info raw))
  (set-box! info-box info)
  (call-backend 'publish! info (unbox handler-box)))

(define (now-playing-clear!)
  (set-box! info-box #f)
  (call-backend 'publish! #f (unbox handler-box)))

(define (now-playing-info)
  (unbox info-box))

(define (now-playing-os-info)
  (call-backend 'os-info))

(define (now-playing-set-command-handler! proc)
  (set-box! handler-box proc)
  (call-backend 'set-handler! proc))
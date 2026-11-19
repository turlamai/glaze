#lang racket/base

;; Packaged acceptance smoke (glaze#131 + the G4 packaged invoke/SSE gate).
;;
;; Two modes, selected by GLAZE_ACCEPTANCE_REPORT:
;;
;;  - unset: persist window state at startup and idle. The zero-env
;;    cold-launch gate installs the deb, strips the masking XDG variables,
;;    and asserts survival plus a state file under $HOME/.config — never
;;    inside the read-only payload.
;;
;;  - set: the page drives a typed invoke, a typed invalid-args rejection,
;;    and an SSE round trip through the REAL bridge (generated glaze.api
;;    client + glaze.on). The confirm route records the page-side facts; a
;;    watcher writes the JSON acceptance report and quits. CI asserts the
;;    report — a miniature executable acceptance manifest in the spirit of
;;    rivet's rivet-acceptance.rktd.
;;
;; Run from source:  racket scripts/coldsmoke/main.rkt
;; Packaged gate:    see the "Zero-env cold launch" step in .github/workflows/ci.yml

(require json
         racket/file
         racket/runtime-path
         glaze
         glaze/window-state
         (only-in glaze/types GString))

(define-runtime-path public "public")

(define app-id "dev.glaze.coldsmoke")
(define bus (make-event-bus))

;; kind -> payload, recorded when the PAGE confirms each bridge fact.
(define facts (make-hash))
(define facts-sema (make-semaphore))
(define expected-kinds '("typed-ok" "invalid-rejected" "sse"))

;; The start handler only posts a semaphore: a thread spawned inside a
;; request handler inherits the request custodian and dies when the
;; response completes, so the delayed broadcast must live on an app-
;; lifetime thread instead.
(define start-sema (make-semaphore))

;; The watcher thread is created BEFORE run-app, so it cannot inherit the
;; current-app parameter; on-ready captures the live instance for the quit.
(define app-box (box #f))

(define-api-routes
 api
 [(POST "api/accept/echo") (accept-echo [msg GString]) (hasheq 'echo msg)]
 [(POST "api/accept/start") (accept-start) (semaphore-post start-sema) (hasheq 'started #t)]
 [(POST "api/accept/confirm")
  (accept-confirm [kind GString] [payload GString])
  (hash-set! facts kind payload)
  (semaphore-post facts-sema)
  (hasheq 'ok #t)])

(define (write-report! ok?)
  (define report
    (hasheq 'ok
            ok?
            'checks
            (for/hasheq ([kind (in-list expected-kinds)])
              (values (string->symbol kind) (hash-ref facts kind #f)))))
  (call-with-output-file (getenv "GLAZE_ACCEPTANCE_REPORT")
                         (lambda (out) (write-json report out))
                         #:exists 'truncate)
  (define app (unbox app-box))
  (if app
      (app-quit! app)
      (exit 0)))

(define (watch-report)
  (define deadline (+ (current-inexact-milliseconds) 30000))
  (let loop ()
    (cond
      [(for/and ([kind (in-list expected-kinds)])
         (hash-has-key? facts kind))
       (write-report! #t)]
      [(> (current-inexact-milliseconds) deadline) (write-report! #f)]
      [else
       (sync/timeout 0.5 facts-sema)
       (loop)])))

(module+ main
  (when (getenv "GLAZE_ACCEPTANCE_REPORT")
    (thread watch-report)
    ;; Give the page's EventSource / native listener a moment to attach
    ;; before the broadcast; the bus is fire-and-forget.
    (thread (lambda ()
              (semaphore-wait start-sema)
              (sleep 1.5)
              (bus-broadcast! bus 'accept-ping (hasheq 'payload "pong")))))
  (run-app #:public-dir public
           #:api api
           #:events bus
           #:title "coldsmoke"
           #:app-id app-id
           #:window-state #t
           #:on-ready (lambda (wv url)
                        (set-box! app-box (current-app))
                        (webview-save-state! wv (default-window-state-path app-id)))))

(provide api
         bus)

#lang racket/base

;; glaze/private/win-stdio: a packaged GUI app without standard handles must
;; never make the Racket runtime allocate a console. The real-world case (a
;; GUI-subsystem exe started from Explorer) cannot be staged inside the test
;; process, so the decision is driven through the injected predicate; the
;; packaged launch itself is covered by the Windows package job's console
;; smoke.

(require rackunit
         racket/port
         glaze/private/win-stdio)

(define outside-out (current-output-port))
(define outside-err (current-error-port))
(define outside-in (current-input-port))

(define (headless thunk)
  (call-with-headless-stdio thunk #:stdio-attached? (lambda () #f)))

;; The test process has real handles (pipes or a console): the predicate
;; classifies it as attached and the thunk runs with the caller's ports. This
;; must hold on every OS: outside Windows there are no Win32 handles to ask
;; about and the answer is #t by definition — a #f there would silence every
;; terminal-launched app (caught by the Linux ARM64 job on glaze#174).
(check-true (procedure? stdio-attached?))
(check-true (stdio-attached?) "a test runner has attached stdio")
(check-eq? (call-with-headless-stdio (lambda () (current-error-port)))
           outside-err
           "attached stdio leaves the ports alone")

;; GLAZE_DEBUG=1 is the deliberate opt-out: without handles, the ports stay
;; real, so the runtime opens a console and the traces become visible.
(check-equal? (call-with-headless-stdio
               (lambda () (list (eq? (current-output-port) outside-out)
                                (eq? (current-error-port) outside-err)
                                (eq? (current-input-port) outside-in)))
               #:stdio-attached? (lambda () #f)
               #:debug? #t)
              '(#t #t #t)
              "GLAZE_DEBUG=1 keeps the real ports even without handles")
(check-true (boolean? debug-trace-enabled?) "debug-trace-enabled? answers for the test process")

;; Headless: all three ports are replaced inside, and only inside.
(check-equal? (headless (lambda ()
                          (list (eq? (current-output-port) outside-out)
                                (eq? (current-error-port) outside-err)
                                (eq? (current-input-port) outside-in)
                                (eq? (read-line) eof))))
              '(#f #f #f #t)
              "headless stdio swaps every port")
(check-eq? (current-output-port) outside-out "output port restored")
(check-eq? (current-error-port) outside-err "error port restored")
(check-eq? (current-input-port) outside-in "input port restored")

;; Writing to the inert ports neither raises nor reaches the caller's
;; streams; an exception inside propagates and still restores the ports.
(check-eq? (headless (lambda ()
                       (displayln "trace")
                       (eprintf "warning\n")
                       (void (read-line))
                       'returned))
           'returned
           "the thunk's value is returned")
(check-exn exn:fail? (lambda () (headless (lambda () (error 'test "boom"))))
             "exceptions cross the boundary")
(check-eq? (current-error-port) outside-err "error port restored after raise")

;; A thread spawned inside the guarded extent inherits the inert ports; one
;; spawned outside keeps the caller's.
(define inherited (box 'pending))
(void
 (headless (lambda ()
             (thread (lambda ()
                       (set-box! inherited (not (eq? (current-error-port) outside-err))))))))
(let loop ([n 0])
  (unless (or (not (eq? (unbox inherited) 'pending)) (>= n 50))
    (sleep 0.1)
    (loop (add1 n))))
(check-true (eq? (unbox inherited) #t) "a child thread inherits headless stdio")

(define outside-worker-result (box 'pending))
(void (thread (lambda ()
                (set-box! outside-worker-result (eq? (current-error-port) outside-err)))))
(let loop ([n 0])
  (unless (or (not (eq? (unbox outside-worker-result) 'pending)) (>= n 50))
    (sleep 0.1)
    (loop (add1 n))))
(check-true (eq? (unbox outside-worker-result) #t) "threads created outside keep the real ports")

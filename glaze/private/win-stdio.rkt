#lang racket/base

;; Headless stdio for packaged GUI apps.
;;
;; A Windows GUI-subsystem executable started from Explorer or a shortcut
;; has no standard handles. The first time such a process touches stdout,
;; stderr or stdin, the Racket runtime allocates a console so the output has
;; somewhere to go (rktio `rktio_std_fd` -> `rktio_create_console`), and the
;; console stays open after exit. Any diagnostic write in the app's closure —
;; a framework trace, a store auto-save warning — is enough to put a black
;; window in front of the user.
;;
;; call-with-headless-stdio runs a thunk with the three standard ports bound
;; to inert ports when, and only when, the process has no attached standard
;; handles. A terminal (`racket backend/main.rkt`, `raco glaze dev`, tests)
;; keeps its real stdio: nothing changes for development or CI. Threads
;; created inside the thunk inherit the inert ports; threads created before
;; run-app keep whatever their creator had.
;;
;; GLAZE_DEBUG=1 opts out on purpose: someone debugging a packaged app then
;; gets the console window, with the framework traces the same variable
;; enables, instead of silence. debug-trace-enabled? is the one definition of
;; that switch for every module that gates its hot-path output on it.

(require racket/port
         (only-in "win-stdio-ffi.rkt" [stdio-attached? handles-attached?]))

(provide stdio-attached?
         call-with-headless-stdio
         debug-trace-enabled?)

;; The answer is fixed for the lifetime of the process, so it is read once.
;; Required statically: a dynamic-require hides the module from raco exe, and
;; a packaged app then fails at startup with a missing-collection error
;; (glaze#173).
(define attached (handles-attached?))

(define (stdio-attached?)
  attached)

(define debug-trace-enabled? (equal? (getenv "GLAZE_DEBUG") "1"))

(define (call-with-headless-stdio thunk
                                  #:stdio-attached? [stdio-attached? stdio-attached?]
                                  #:debug? [debug? debug-trace-enabled?])
  (if (or debug? (stdio-attached?))
      (thunk)
      (parameterize ([current-input-port (open-input-bytes #"")]
                     [current-output-port (open-output-nowhere)]
                     [current-error-port (open-output-nowhere)])
        (thunk))))

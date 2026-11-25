#lang racket/base

;; Does this process have open standard handles?
;;
;; Windows only in effect; every other OS answers #t — nothing may silence a
;; terminal there. The Win32 bindings resolve on first use (the pattern of
;; windows-capture.rkt), so this module is required statically — a
;; runtime-computed dynamic-require is a dependency raco exe cannot trace, and
;; a packaged app then dies at startup with "collection not found".
;;
;; GetStdHandle is the check the Racket runtime itself defers until a port is
;; first used; asking it here never triggers rktio's console allocation.

(require ffi/unsafe)

(provide stdio-attached?)

(define windows? (eq? (system-type 'os) 'windows))

(define (kernel32)
  (ffi-lib "kernel32"))

(define (GetStdHandle which)
  ((get-ffi-obj "GetStdHandle" (kernel32) (_fun _uint -> _uintptr)) which))

(define STD_INPUT_HANDLE #xfffffff6)
(define STD_OUTPUT_HANDLE #xfffffff5)
(define STD_ERROR_HANDLE #xfffffff4)

(define INVALID_HANDLE_VALUE (sub1 (expt 2 64)))

(define (handle-open? which)
  (define h (GetStdHandle which))
  (and (> h 0) (not (= h INVALID_HANDLE_VALUE))))

(define (stdio-attached?)
  (if windows?
      (and (handle-open? STD_INPUT_HANDLE)
           (handle-open? STD_OUTPUT_HANDLE)
           (handle-open? STD_ERROR_HANDLE))
      #t))

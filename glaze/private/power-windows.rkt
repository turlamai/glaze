#lang racket/base

;; Use independent Windows power request handles, rather than thread-global
;; SetThreadExecutionState flags. Overlapping tokens cannot clear each other.
(require ffi/unsafe
         "../ffi-discovery.rkt")

(provide supported? acquire!)

(define kernel (ffi-lib* "kernel32" '(#f)))
(define (bind name type)
  (and kernel (get-ffi-obj name kernel type (lambda () #f))))
;; REASON_CONTEXT has a DWORD version, DWORD flags and a union whose
;; largest member is the detailed reason (two pointers and two DWORDs).
(define-cstruct _reason-context
  ([version _uint32] [flags _uint32] [reason _pointer]
   [reserved1 _uintptr] [reserved2 _uintptr]))
(define create-request (bind "PowerCreateRequest" (_fun _reason-context-pointer -> _pointer)))
(define set-request (bind "PowerSetRequest" (_fun _pointer _int -> _bool)))
(define clear-request (bind "PowerClearRequest" (_fun _pointer _int -> _bool)))
(define close-handle (bind "CloseHandle" (_fun _pointer -> _bool)))

(define (supported?)
  (and create-request set-request clear-request close-handle #t))

(define (acquire! kind reason)
  (and (supported?)
       (let* ([wide (cast reason _string/utf-16 _pointer)]
              [context (make-reason-context 0 1 wide 0 0)]
              [handle (create-request context)]
              [request-type (if (eq? kind 'display) 0 1)])
         (and handle
              (not (= (cast handle _pointer _intptr) -1))
              (cond
                [(set-request handle request-type)
                 (lambda ()
                   ;; Closing the handle also removes all its assertions.
                   (clear-request handle request-type)
                   (close-handle handle))]
                [else (close-handle handle) #f])))))

#lang racket/base

;; Scoped, optional idle-sleep assertions. Each token owns one native
;; assertion; releasing it twice or passing an unrelated value is harmless.
(require racket/string
         racket/contract)

(provide (contract-out [power-supported? (-> boolean?)]
                       [power-diagnostic (-> (or/c string? #f))]
                       [keep-awake-acquire! (->* (string?) (#:kind (or/c 'system 'display)) (or/c keep-awake-token? #f))]
                       [keep-awake-release! (-> any/c boolean?)]
                       [keep-awake-token? (-> any/c boolean?)]
                       [call-with-keep-awake (->* (string? procedure?) (#:kind (or/c 'system 'display)) any)]))

(struct keep-awake-token (release [active? #:mutable]))
(define token-lock (make-semaphore 1))

(define (backend-module)
  (case (system-type 'os)
    [(macosx) 'glaze/private/power-macos]
    [(windows) 'glaze/private/power-windows]
    [(unix) 'glaze/private/power-linux]
    [else #f]))

(define (backend name)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (and (backend-module) (dynamic-require (backend-module) name))))

(define (power-supported?)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define probe (backend 'supported?))
    (and probe (probe) #t)))

(define (power-diagnostic)
  (and (not (power-supported?))
       "Native idle-sleep assertion backend unavailable; check platform power services."))

(define (keep-awake-acquire! reason #:kind [kind 'system])
  (when (string=? (string-trim reason) "")
    (raise-argument-error 'keep-awake-acquire! "nonempty reason string" reason))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define acquire (backend 'acquire!))
    (define release (and acquire (acquire kind (string->immutable-string reason))))
    (and (procedure? release) (keep-awake-token release #t))))

(define (keep-awake-release! token)
  (and (keep-awake-token? token)
       (call-with-semaphore
        token-lock
        (lambda ()
          (and (keep-awake-token-active? token)
               (with-handlers ([exn:fail? (lambda (_) #f)])
                 (and ((keep-awake-token-release token))
                      (begin
                        (set-keep-awake-token-active?! token #f)
                        #t))))))))

;; Fail explicitly if no assertion can be obtained; never run a critical
;; operation while implying that the machine is protected from idle sleep.
(define (call-with-keep-awake reason thunk #:kind [kind 'system])
  (define token #f)
  (dynamic-wind
   (lambda ()
     (set! token (keep-awake-acquire! reason #:kind kind))
     (unless token (error 'call-with-keep-awake "cannot acquire idle-sleep assertion")))
   thunk
   (lambda ()
     (when token (keep-awake-release! token)))))

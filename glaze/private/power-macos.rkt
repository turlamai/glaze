#lang racket/base

(require ffi/unsafe
         "../ffi-discovery.rkt")

(provide supported? acquire!)

(define iokit (ffi-lib* "/System/Library/Frameworks/IOKit.framework/IOKit" '(#f)))
(define cf (ffi-lib* "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation" '(#f)))
(define (bind lib name type)
  (and lib (get-ffi-obj name lib type (lambda () #f))))

(define make-string
  (bind cf "CFStringCreateWithCString" (_fun _pointer _string/utf-8 _uint32 -> _pointer)))
(define cf-release (bind cf "CFRelease" (_fun _pointer -> _void)))
(define assertion-create
  (bind iokit "IOPMAssertionCreateWithName"
        (_fun _pointer _uint32 _pointer (id : (_ptr o _uint32))
              -> (status : _int32) -> (values status id))))
(define assertion-release
  (bind iokit "IOPMAssertionRelease" (_fun _uint32 -> _int32)))

(define (supported?)
  (and make-string cf-release assertion-create assertion-release #t))

(define (acquire! kind reason)
  (and (supported?)
       (let ([type (make-string #f
                                (if (eq? kind 'display)
                                    "PreventUserIdleDisplaySleep"
                                    "PreventUserIdleSystemSleep")
                                #x08000100)]
             [name (make-string #f reason #x08000100)])
         (dynamic-wind
          void
          (lambda ()
            (and type name
                 (let-values ([(status id) (assertion-create type 255 name)])
                   (and (zero? status)
                        (lambda () (zero? (assertion-release id)))))))
          (lambda ()
            (when type (cf-release type))
            (when name (cf-release name)))))))

#lang racket/base

(require racket/list)

;; Shared registry of extra GMainContexts that the platform webview pump
;; must iterate. The Linux now-playing backend owns a private context for
;; its GDBus connection; dispatching its callbacks from a second Racket
;; pump thread corrupts the scheduler under hosted WebKit (podlens#63),
;; while the webview pump thread already runs GLib/WebKit Racket callbacks
;; safely. When a webview pump is live it iterates every registered context
;; and the backend's own pump stands down.

(provide register-main-context!
         unregister-main-context!
         registered-main-contexts
         set-external-pump!
         external-pump?)

(define contexts-box (box '()))
(define external-pump-box (box #f))

(define (register-main-context! ctx)
  (set-box! contexts-box (cons ctx (unbox contexts-box))))

(define (unregister-main-context! ctx)
  (set-box! contexts-box (remove ctx (unbox contexts-box))))

(define (registered-main-contexts)
  (unbox contexts-box))

(define (set-external-pump! on?)
  (set-box! external-pump-box (and on? #t)))

(define (external-pump?)
  (unbox external-pump-box))
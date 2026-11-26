#lang racket/base

;; Cross-platform system tray demo. Quit from the tray menu.
;; Run: racket examples/tray-demo.rkt

(require glaze)

(define clicks (box 0))
(define quit-ready (make-semaphore 0))

(define t
  (make-tray
   #:icon #f
   #:tooltip "Glaze Tray Demo"
   #:menu
   (list (make-menu-item "About" #:action (lambda () (displayln "[tray] Glaze tray demo")))
         (menu-separator)
         (make-menu-item "Quit" #:action (lambda () (semaphore-post quit-ready))))
   #:on-event (lambda (event)
                (set-box! clicks (add1 (unbox clicks)))
                (printf "[tray] event: ~a (~a clicks)\n" event (unbox clicks)))))

;; A stub has no visible menu, so waiting for Quit would strand the process.
;; Close native resources on the owning thread, not inside a tray callback.
(dynamic-wind void
              (lambda ()
                (cond
                  [(eq? (tray-backend t) 'stub)
                   (displayln "[tray] Native tray unavailable; exiting." (current-error-port))]
                  [else
                   (displayln "[tray] icon is live; use the tray menu to quit")
                   (sync quit-ready)
                   (void)]))
              (lambda () (tray-close t)))

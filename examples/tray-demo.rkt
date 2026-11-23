#lang racket/base

;; Cross-platform system tray demo: icon in the menu bar / notification area
;; with a working menu and click events. Quit from the tray menu.
;;
;; Run: racket examples/tray-demo.rkt

(require glaze)

(define clicks (box 0))

(define t
  (make-tray
   #:icon #f
   #:tooltip "Glaze Tray Demo"
   #:menu
   (list (make-menu-item "About" #:action (lambda () (displayln "[tray] Glaze tray demo")))
         (menu-separator)
         (make-menu-item "Update tooltip" #:action (lambda () (tray-set-tooltip! t "updated!")))
         (menu-separator)
         (make-menu-item "Quit" #:action (lambda () (exit 0))))
   ;; 'click / 'double-click on the icon itself (not the menu).
   #:on-event (lambda (event)
                (set-box! clicks (add1 (unbox clicks)))
                (displayln "[tray] event: " event)
                (tray-set-tooltip! t (format "Glaze Tray Demo · ~a click(s)" (unbox clicks))))))

(displayln "[tray] icon is live — left-click it, or use the tray menu to quit")
;; Keep the process alive for the tray; the Quit menu item exits.
(let loop ()
  (sleep 1)
  (loop))

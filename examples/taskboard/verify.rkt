#lang racket/base

;; Non-interactive acceptance check for the Taskboard example.
;;
;; It opens the real system WebView, waits for the page to commit, checks the
;; title and bootstrap URL, captures a PNG and closes the window. It is the
;; same pattern `raco glaze init` generates; extend it with product-specific
;; route assertions when the example grows.

(require racket/file
         glaze
         "main.rkt")

(define verdicts '())
(define deadline-ms 15000)

;; Keep acceptance runs off the user's real task list.
(define verify-root (make-temporary-file "taskboard-verify-~a" 'directory))
(void (putenv "TASKBOARD_DATA_DIR" (path->string verify-root)))

(define-values (_kind stop)
  (run-app #:public-dir public
           #:api api
           #:events bus
           #:title "Taskboard"
           #:window-state #f
           #:on-ready
           (lambda (wv url)
             (define deadline (+ (current-inexact-milliseconds) deadline-ms))
             (define loaded?
               (let loop ()
                 (cond
                   [(equal? (webview-title wv) "Taskboard") #t]
                   [(>= (current-inexact-milliseconds) deadline) #f]
                   [else
                    (sleep 0.1)
                    (loop)])))
             ;; A committed title is not a painted page: give the compositor a
             ;; moment so the screenshot shows content instead of a white flash.
             (when loaded?
               (sleep 0.5))
             (define shot (and loaded? (webview-capture! wv)))
             (when shot
               (printf "[verify] screenshot = ~a\n" shot))
             (set! verdicts
                   (list (cons 'page-loaded loaded?)
                         (cons 'url (equal? (webview-url wv) url))
                         (cons 'capture (and shot (file-exists? shot) (> (file-size shot) 0)))))
             (webview-close wv))))

(void (stop))

(when (directory-exists? verify-root)
  (delete-directory/files verify-root))

(for ([verdict (in-list verdicts)])
  (printf "[verify] ~a = ~a\n" (car verdict) (cdr verdict)))

(unless (and (pair? verdicts) (andmap cdr verdicts))
  (eprintf "[verify] native UI verification failed\n")
  (exit 1))

(displayln "[verify] ALL PASS")

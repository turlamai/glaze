#lang racket/base

;; Regression tests for the support-bundle core: home-path redaction,
;; bounded config-tree collection, entry assembly, and ZIP writing.

(require racket/file
         racket/string
         file/unzip
         glaze-cli/private/support-bundle)

(module+ test
  (require rackunit)

  ;; ---- redact-home ------------------------------------------------------
  (check-equal? (redact-home "/home/alice/app/main.rkt" "/home/alice") "~/app/main.rkt")
  (check-equal? (redact-home "C:\\Users\\alice\\app" "C:\\Users\\alice") "~\\app")
  ;; trailing-separator variant of the home path is redacted too
  (check-equal? (redact-home "/home/alice/x" "/home/alice/") "~/x")
  (check-equal? (redact-home "no path here" "/home/alice") "no path here")
  ;; link targets arrive backslash-escaped from `raco pkg show -l`
  (check-equal? (redact-home "C:\\\\Users\\\\alice\\\\glaze" "C:\\Users\\alice") "~\\\\glaze")
  (check-equal? (redact-home "C:/Users/alice/glaze" "C:\\Users\\alice") "~/glaze")

  ;; ---- redact-jsexpr ----------------------------------------------------
  (define redacted
    (redact-jsexpr
     (hash 'collection "/home/alice/glaze" 'problems (list "link /home/alice/x is broken") 'count 3)
     "/home/alice"))
  (check-equal? (hash-ref redacted 'collection) "~/glaze")
  (check-equal? (car (hash-ref redacted 'problems)) "link ~/x is broken")
  (check-equal? (hash-ref redacted 'count) 3)

  ;; multiple home roots: a redirected Racket home plus the real account
  ;; profile must both be redacted (the APPDATA-under-real-home leak).
  (define multi
    (redact-jsexpr (hash 'config-dir "/home/alice/.config" 'collection "/home/alice/glaze")
                   (list "/home/alice/.racket" "/home/alice")))
  (check-equal? (hash-ref multi 'config-dir) "~/.config")
  (check-equal? (hash-ref multi 'collection) "~/glaze")
  (check-equal? (redact-text "C:\\Users\\alice\\AppData\\Roaming"
                             (list "C:\\Users\\alice\\.racket" "C:\\Users\\alice"))
                "~\\AppData\\Roaming")

  ;; ---- collect-bundle-files ---------------------------------------------
  (define root (make-temporary-file "glaze-bundle-test-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define app-dir (build-path root "dev.example.app"))
     (make-directory* app-dir)
     (call-with-output-file (build-path app-dir "window-state.json")
                            (lambda (o) (display "{\"x\":1}" o)))
     (call-with-output-file (build-path app-dir "app.log") (lambda (o) (display "log line" o)))
     (call-with-output-file (build-path app-dir "notes.txt") (lambda (o) (display "not collected" o)))
     ;; oversized logs are skipped
     (call-with-output-file (build-path app-dir "huge.log")
                            (lambda (o) (display (make-string (* 300 1024) #\x) o)))
     (define files (collect-bundle-files root))
     (define names (map car files))
     (check-equal? (length files) 2)
     (check-not-false (member "config/dev.example.app/window-state.json" names))
     (check-not-false (member "config/dev.example.app/app.log" names))
     ;; missing root yields no entries, not an error
     (check-equal? (collect-bundle-files (build-path root "absent")) '()))
   (lambda () (delete-directory/files root)))

  ;; ---- bundle-entries + write-bundle! -----------------------------------
  (define entries
    (bundle-entries "/home/alice"
                    (hash 'config-dir "/home/alice/.config")
                    (hash 'collection "/home/alice/glaze")
                    #f
                    (list (cons "config/app/window-state.json" "{\"path\":\"/home/alice/x\"}"))))
  (check-equal? (length entries) 3)
  (check-true (string-contains? (cdr (assoc "environment.json" entries)) "~/.config"))
  (check-false (string-contains? (cdr (assoc "doctor.json" entries)) "/home/alice"))
  (check-true (string-contains? (cdr (assoc "config/app/window-state.json" entries)) "~/x"))

  (define zip-path (make-temporary-file "glaze-bundle-test-~a.zip"))
  (dynamic-wind void
                (lambda ()
                  (write-bundle! entries zip-path)
                  (check-true (> (file-size zip-path) 0))
                  (define zip-names
                    (map bytes->string/utf-8 (zip-directory-entries (read-zip-directory zip-path))))
                  (check-not-false (member "environment.json" zip-names))
                  (check-not-false (member "doctor.json" zip-names))
                  (check-not-false (member "config/app/window-state.json" zip-names)))
                (lambda ()
                  (when (file-exists? zip-path)
                    (delete-file zip-path)))))

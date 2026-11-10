#lang racket/base

(require racket/file
         racket/list
         racket/string
         rackunit
         glaze/private/build-entry)

(test-case "entry generation distinguishes real main submodules from text"
  (define temp-dir (make-temporary-file "glaze-build-entry-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (define entry (build-path temp-dir "entry.rkt"))
     (define (generate source)
       (call-with-output-file entry (lambda (output) (display source output)) #:exists 'replace)
       (entry-module-source entry))
     (check-false (string-contains?
                   (generate "#lang racket/base\n;; (module+ main (error \"not real\"))\n")
                   "(require (submod \"entry.rkt\" main))"))
     (check-true (string-contains?
                  (generate "#lang racket/base\n(module+ main (displayln \"runs\"))\n")
                  "(require (submod \"entry.rkt\" main))"))
     (check-true (string-contains? ((default-entry-template) entry) "find-system-path 'run-file")))
   (lambda () (delete-directory/files temp-dir))))

(test-case "bare build derives the app name from a trailing-separator project dir"
  ;; `path-only` may return the project directory with a trailing separator
  ;; and `file-name-from-path` answers #f for that shape — the 0.18 bare
  ;; `raco glaze build` (no --name) crashed on exactly this input. The
  ;; derivation must produce the directory name either way.
  (define temp-dir (make-temporary-file "glaze-build-name-~a" 'directory))
  (dynamic-wind void
                (lambda ()
                  (define dir-name (path->string (last (explode-path temp-dir))))
                  (check-equal? (project-name-from-entry (build-path temp-dir "main.rkt")) dir-name)
                  (parameterize ([current-directory temp-dir])
                    (check-equal? (project-name-from-entry "main.rkt") dir-name))
                  ;; A nested entry names the directory holding it, not the project root:
                  ;; the pre-fix behavior derives from the entry's own directory.
                  (make-directory* (build-path temp-dir "app"))
                  (check-equal? (project-name-from-entry (build-path temp-dir "app" "main.rkt"))
                                "app"))
                (lambda () (delete-directory/files temp-dir))))

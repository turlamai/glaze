#lang racket/base
(require rackunit racket/file racket/runtime-path)
(define-runtime-path init "../glaze-cli/private/init.rkt")
(define init-project (dynamic-require init 'init-project))
(define dir (make-temporary-file "glaze-desktop-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (parameterize ([current-directory dir])
     (init-project "sample")
     (define html (file->string "sample/public/index.html"))
     (define css (file->string "sample/public/desktop.css"))
     (check-true (regexp-match? #rx"desktop[.]css" html))
     (check-true (regexp-match? #rx"<main class=\"workspace\" tabindex=\"0\"" html))
     (check-true (regexp-match? #rx"grid-template-rows: auto minmax[(]0, 1fr[)] auto" css))
     (check-true (regexp-match? #rx"[.]workspace [{][^}]*overflow: auto" css))
     (check-true (regexp-match? #rx"prefers-color-scheme: dark" css))
     (check-true (regexp-match? #rx"forced-colors: active" css))))
 (lambda () (delete-directory/files dir)))

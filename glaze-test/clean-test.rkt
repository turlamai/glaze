#lang racket/base

;; Regression tests for the build-artifact cleanup pure core. The safety rules
;; are exercised on a fixture project root and pre-read filesystem kinds, so the
;; tests delete nothing: a clean target must be a non-empty relative path
;; strictly inside the project root (never the root itself or an escape), a
;; missing target is skipped, and any unsafe target fails the whole plan closed.
;; Argument parsing is guarded too.

(require racket/file
         racket/list
         racket/path
         racket/port
         rackunit
         glaze/private/clean
         glaze-cli/private/clean)

(define root (path->complete-path (build-path (current-directory) "clean-fixture-project")))

;; String-keyed fact tables use equal? hashing (the core looks names up as
;; strings), so build them with make-immutable-hash.
(define (table . kvs)
  (make-immutable-hash (let loop ([xs kvs])
                         (if (null? xs)
                             '()
                             (cons (cons (car xs) (cadr xs)) (loop (cddr xs)))))))

;; ---- clean-candidate-problems --------------------------------------------

(check-equal? (clean-candidate-problems root "dist") '())
(check-equal? (clean-candidate-problems root "build/out") '())
(check-equal? (clean-candidate-problems root "compiled") '())
(check-pred pair? (clean-candidate-problems root ""))
(check-pred pair? (clean-candidate-problems root #f))
(check-pred pair? (clean-candidate-problems root (path->string (build-path root "dist"))))
(check-pred pair? (clean-candidate-problems root ".."))
(check-pred pair? (clean-candidate-problems root "."))
(check-pred pair? (clean-candidate-problems root "../sibling"))
(check-pred pair? (clean-candidate-problems root "dist/.."))

;; ---- make-clean-plan ------------------------------------------------------

(define present (make-clean-plan root '("dist") (table "dist" 'directory)))
(check-true (hash-ref present 'ok))
(check-equal? (hash-ref present 'problems) '())
(check-equal? (hash-ref present 'remove) (list (hasheq 'name "dist" 'kind "directory")))
(check-equal? (hash-ref present 'skipped) '())

(define absent (make-clean-plan root '("dist") (table "dist" 'missing)))
(check-true (hash-ref absent 'ok))
(check-equal? (hash-ref absent 'remove) '())
(check-equal? (hash-ref absent 'skipped) '("dist"))

(define two (make-clean-plan root '("dist" "compiled") (table "dist" 'directory "compiled" 'missing)))
(check-true (hash-ref two 'ok))
(check-equal? (hash-ref two 'remove) (list (hasheq 'name "dist" 'kind "directory")))
(check-equal? (hash-ref two 'skipped) '("compiled"))

(define link-plan (make-clean-plan root '("dist") (table "dist" 'link)))
(check-true (hash-ref link-plan 'ok))
(check-equal? (hash-ref link-plan 'remove) (list (hasheq 'name "dist" 'kind "link")))

(define dirlink-plan (make-clean-plan root '("dist") (table "dist" 'directory-link)))
(check-equal? (hash-ref dirlink-plan 'remove) (list (hasheq 'name "dist" 'kind "directory-link")))

(define unsafe (make-clean-plan root '("..") (table)))
(check-false (hash-ref unsafe 'ok))
(check-pred pair? (hash-ref unsafe 'problems))
(check-equal? (hash-ref unsafe 'remove) '())

(define mixed (make-clean-plan root '("dist" "../escape") (table "dist" 'directory)))
(check-false (hash-ref mixed 'ok))
;; fail-closed: an unsafe target invalidates the whole plan, even the safe one.
(check-equal? (hash-ref mixed 'remove) '())

;; ---- parse-clean-arguments -----------------------------------------------

(define-values (pd0 opts0) (parse-clean-arguments '()))
(check-false pd0)
(check-false (hash-ref opts0 'out #f))
(check-false (hash-ref opts0 'compiled? #f))
(check-false (hash-ref opts0 'dry-run? #f))
(check-false (hash-ref opts0 'json? #f))

(define-values (pd1 opts1)
  (parse-clean-arguments '("proj" "--out" "build" "--compiled" "--dry-run" "--json")))
(check-equal? pd1 "proj")
(check-equal? (hash-ref opts1 'out) "build")
(check-true (hash-ref opts1 'compiled?))
(check-true (hash-ref opts1 'dry-run?))
(check-true (hash-ref opts1 'json?))

(define-values (pd2 opts2) (parse-clean-arguments '("--out" "dist")))
(check-false pd2)
(check-equal? (hash-ref opts2 'out) "dist")

(check-exn exn:fail? (lambda () (parse-clean-arguments '("--out" "a" "--out" "b"))))
(check-exn exn:fail? (lambda () (parse-clean-arguments '("--json" "--json"))))
(check-exn exn:fail? (lambda () (parse-clean-arguments '("--compiled" "--compiled"))))
(check-exn exn:fail? (lambda () (parse-clean-arguments '("--bogus"))))
(check-exn exn:fail? (lambda () (parse-clean-arguments '("a" "b"))))
(check-exn exn:fail? (lambda () (parse-clean-arguments '("--out"))))

;; ---- end-to-end CLI shell -------------------------------------------------

;; The shell gathers real filesystem kinds and deletes only safe generated
;; directories. No signing or network is involved, so this leg runs on every
;; platform: dry-run deletes nothing, the default clean removes dist but keeps
;; source and bytecode, --compiled removes the bytecode cache, and an unsafe
;; --out fails closed without touching source.
(define work (make-temporary-directory "glaze-clean-~a"))
(dynamic-wind
 void
 (lambda ()
   (define (put rel)
     (define p (build-path work rel))
     (make-directory* (path-only p))
     (call-with-output-file p (lambda (out) (display "x" out)) #:exists 'truncate/replace))
   (put "main.rkt")
   (put "dist/app.exe")
   (put "compiled/main_rkt.zo")
   (define (invoke . args)
     (parameterize ([current-output-port (open-output-nowhere)])
       (clean-command (cons (path->string work) args))))
   (check-equal? (invoke "--dry-run" "--compiled") 0)
   (check-true (directory-exists? (build-path work "dist")))
   (check-true (directory-exists? (build-path work "compiled")))
   (check-equal? (invoke) 0)
   (check-false (directory-exists? (build-path work "dist")))
   (check-true (directory-exists? (build-path work "compiled")))
   (check-true (file-exists? (build-path work "main.rkt")))
   (check-equal? (invoke "--compiled") 0)
   (check-false (directory-exists? (build-path work "compiled")))
   (check-true (file-exists? (build-path work "main.rkt")))
   (check-equal? (invoke "--out" "..") 1)
   (check-true (file-exists? (build-path work "main.rkt"))))
 (lambda () (delete-directory/files work)))

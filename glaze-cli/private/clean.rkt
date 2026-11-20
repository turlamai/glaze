#lang racket/base

;; CLI shell for build-artifact cleanup. It resolves the project root, gathers
;; the filesystem kind of each candidate generated directory, and asks the pure
;; core for a removal plan. Only when the plan is ok (every target a safe,
;; in-root generated path) does it delete anything; --dry-run reports the plan
;; without deleting. Deletion removes files and links as links and never
;; traverses a symlink's target, so a generated directory that happens to be a
;; junction cannot redirect the cleaner into source.

(require json
         racket/file
         racket/list
         racket/path
         glaze/private/clean)

(provide clean-command)

;; Remove a generated path by its link kind, never its destination. Racket
;; reports Windows junctions / directory symlinks as directory-link and needs
;; delete-directory for that kind; a plain directory is removed recursively.
(define (remove-generated-path! path)
  (define kind (file-or-directory-type path #f))
  (case kind
    [(link file)
     (delete-file path)
     #t]
    [(directory-link)
     (delete-directory path)
     #t]
    [(directory)
     (delete-directory/files path)
     #t]
    [else #f]))

(define (clean-command rest)
  (define-values (project-dir options) (parse-clean-arguments rest))
  (define root (path->complete-path (or project-dir (current-directory))))
  (define json? (hash-ref options 'json? #f))
  (define dry-run? (hash-ref options 'dry-run? #f))
  (define out (hash-ref options 'out "dist"))
  (define candidates
    (cons out
          (if (hash-ref options 'compiled? #f)
              (list "compiled")
              '())))
  (define facts
    (for/hash ([name (in-list candidates)])
      (define path (build-path root name))
      (values name (or (file-or-directory-type path #f) 'missing))))
  (define plan (make-clean-plan root candidates facts))
  (define ok? (hash-ref plan 'ok))
  (define removed
    (cond
      [(or dry-run? (not ok?)) '()]
      [else
       (for/list ([entry (in-list (hash-ref plan 'remove))])
         (define name (hash-ref entry 'name))
         (remove-generated-path! (build-path root name))
         name)]))
  (cond
    [json?
     (write-json
      (hash-set* plan 'project-root (path->string root) 'dry-run dry-run? 'removed removed))
     (newline)]
    [(not ok?)
     (printf "clean FAILED:\n")
     (for ([problem (in-list (hash-ref plan 'problems))])
       (printf "  - ~a\n" problem))]
    [dry-run?
     (printf "clean (dry run) for ~a:\n" (path->string root))
     (for ([entry (in-list (hash-ref plan 'remove))])
       (printf "  would remove ~a (~a)\n" (hash-ref entry 'name) (hash-ref entry 'kind)))
     (for ([name (in-list (hash-ref plan 'skipped))])
       (printf "  skip ~a (absent)\n" name))]
    [else
     (for ([name (in-list removed)])
       (printf "removed ~a\n" name))
     (for ([name (in-list (hash-ref plan 'skipped))])
       (printf "  skip ~a (absent)\n" name))
     (when (null? removed)
       (displayln "nothing to clean"))])
  (if ok? 0 1))

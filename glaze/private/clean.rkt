#lang racket/base

;; Build-artifact cleanup — the glaze analogue of rivet's `clean` command.
;; glaze's inspect map names `dist` as the project's generated path (the default
;; build output); this command removes that directory, an optional custom
;; --out build directory, and (with --compiled) the project-root Racket bytecode
;; cache. It never touches source files.
;;
;; The pure functions here turn a project root, a list of candidate generated
;; names, and a table of pre-read filesystem kinds into a removal PLAN, so the
;; safety rules are regression-testable without deleting anything: a candidate
;; must be a non-empty relative path strictly inside the project root (never the
;; root itself, never an escape via ".."), and a missing candidate is skipped
;; rather than treated as an error. Any unsafe candidate fails the whole plan
;; closed (ok = #f) so the shell removes nothing when a target is ambiguous.
;; The CLI shell gathers the kinds, prints the plan, and only then performs the
;; deletion — removing files and links as links, never traversing a symlink's
;; target.

(require racket/list
         racket/match
         racket/path
         racket/string)

(provide parse-clean-arguments
         clean-candidate-problems
         make-clean-plan)

;; ---- safety ---------------------------------------------------------------

;; A resolved path is strictly within root when root's component sequence is a
;; proper prefix of the path's. Both are complete paths, so the comparison is
;; independent of the current directory.
(define (strictly-within? path root)
  (define path-components (explode-path path))
  (define root-components (explode-path root))
  (and (> (length path-components) (length root-components))
       (equal? (take path-components (length root-components)) root-components)))

;; A clean target must be a non-empty relative path that resolves strictly
;; inside the project root. Absolute paths, the root itself, and any escape
;; (e.g. ".." or "../sibling") are rejected so the cleaner can never be pointed
;; at source or at a directory outside the project.
(define (clean-candidate-problems root candidate)
  (define problems '())
  (define (problem! fmt . args)
    (set! problems (cons (apply format fmt args) problems)))
  (cond
    [(not (and (string? candidate) (non-empty-string? candidate)))
     (problem! "clean target must be a non-empty relative path")]
    [(absolute-path? candidate)
     (problem! "clean target ~a must be relative to the project root" candidate)]
    [else
     (define root-complete (path->complete-path root))
     (define resolved (simplify-path (path->complete-path (build-path root candidate) root-complete)))
     (cond
       [(equal? resolved root-complete)
        (problem! "clean target ~a must not be the project root itself" candidate)]
       [(not (strictly-within? resolved root-complete))
        (problem! "clean target ~a escapes the project root" candidate)])])
  (reverse problems))

;; ---- removal plan ---------------------------------------------------------

;; candidates is an ordered list of relative generated names; facts is an
;; equal?-keyed table mapping each name to its filesystem kind (the symbols
;; file-or-directory-type returns: file, directory, link, directory-link, or
;; missing). The result is a JSON-friendly plan: ok, an ordered problem list,
;; the entries to remove (name + kind), and the names skipped because absent.
(define (make-clean-plan root candidates facts)
  (define problems '())
  (define (problem! fmt . args)
    (set! problems (cons (apply format fmt args) problems)))
  (define remove '())
  (define skipped '())
  (for ([name (in-list candidates)])
    (define safety (clean-candidate-problems root name))
    (cond
      [(pair? safety)
       (for ([p (in-list safety)])
         (problem! "~a" p))]
      [else
       (define kind (hash-ref facts name 'missing))
       (if (eq? kind 'missing)
           (set! skipped (cons name skipped))
           (set! remove (cons (hasheq 'name name 'kind (symbol->string kind)) remove)))]))
  (hasheq 'ok
          (null? problems)
          'problems
          (reverse problems)
          'remove
          (if (null? problems)
              (reverse remove)
              '())
          'skipped
          (reverse skipped)))

;; ---- argument parsing -----------------------------------------------------

;; [ <project-dir> ] [ --out DIR ] [ --compiled ] [ --dry-run ] [ --json ]
;; The project directory is the only positional argument (default: the current
;; directory, resolved by the shell). --out names the build output directory
;; (default "dist"); --compiled also removes the project-root bytecode cache.
;; Every option may appear at most once; unknown flags and a second positional
;; are rejected so a typo cannot silently widen what gets deleted.
(define (parse-clean-arguments arguments)
  (let loop ([remaining arguments]
             [options (hasheq)]
             [project-dir #f])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'clean (format "~a may be specified only once" key))
          (loop tail (hash-set options key value) project-dir)))
    (match remaining
      ['() (values project-dir options)]
      [(list* "--out" value tail) (with 'out tail value)]
      [(list* "--compiled" tail) (with 'compiled? tail #t)]
      [(list* "--dry-run" tail) (with 'dry-run? tail #t)]
      [(list* "--json" tail) (with 'json? tail #t)]
      [(cons argument tail)
       (cond
         [(string-prefix? argument "--")
          (raise-arguments-error 'clean "unknown argument" "argument" argument)]
         [project-dir
          (raise-arguments-error 'clean
                                 "only one project directory may be given"
                                 "values"
                                 (list project-dir argument))]
         [else (loop tail options argument)])])))

#lang racket/base

;; Acceptance evidence envelope and cross-platform matrix aggregation.
;;
;; This is the data half of rivet's `acceptance` / `matrix` pair, adapted
;; to Glaze's single shared UI: a gate runs on one OS and emits a bounded,
;; self-describing report; `matrix` folds the per-platform reports into the
;; G4 cross-platform conformance matrix (docs/1.0-plan.md) with a
;; fail-closed rollup. Pure data — no process spawning, no I/O — so the
;; aggregation is unit-testable without a GUI or a second machine.

(require racket/list
         racket/string)

(provide acceptance-contract-version
         acceptance-product
         current-platform
         acceptance-envelope
         leg-error
         aggregate-matrix)

(define acceptance-contract-version 1)
(define acceptance-product "Glaze")

;; The OS tag a report carries. Matches (system-type 'os): windows /
;; macosx / unix.
(define (current-platform)
  (symbol->string (system-type 'os)))

;; Producer helper: wrap a gate's verdict in the shared envelope.
(define (acceptance-envelope gate platform ok checks)
  (hasheq 'contract-version
          acceptance-contract-version
          'product
          acceptance-product
          'gate
          gate
          'platform
          platform
          'ok
          ok
          'checks
          checks))

(define (non-empty-string? v)
  (and (string? v) (> (string-length v) 0)))

;; Validate a parsed report. Returns #f when it is a well-formed envelope,
;; otherwise a human-readable reason. Fail closed: anything missing or
;; mistyped is rejected rather than silently treated as a passing leg.
(define (leg-error r)
  (cond
    [(not (hash? r)) "report is not a JSON object"]
    [(not (equal? (hash-ref r 'contract-version #f) acceptance-contract-version))
     "unsupported or missing contract-version"]
    [(not (equal? (hash-ref r 'product #f) acceptance-product)) "not a Glaze acceptance report"]
    [(not (non-empty-string? (hash-ref r 'gate #f))) "missing or empty gate"]
    [(not (non-empty-string? (hash-ref r 'platform #f))) "missing or empty platform"]
    [(not (boolean? (hash-ref r 'ok #f))) "missing or non-boolean ok"]
    [else #f]))

;; Fold parsed reports into the cross-platform matrix. Each leg is bounded
;; to {platform, gate, ok} — the full per-gate checks stay in the source
;; reports, so the matrix never grows with payload size. Duplicate
;; (platform, gate) legs are deduplicated when they agree and flagged when
;; they conflict. The rollup is ok only when every leg passed and no
;; report was malformed.
(define (aggregate-matrix reports)
  (define problems '())
  (define (problem! msg)
    (set! problems (cons msg problems)))
  (define seen (make-hash))
  (define legs '())
  (for ([r (in-list reports)]
        [i (in-naturals)])
    (define err (leg-error r))
    (cond
      [err (problem! (format "report ~a: ~a" i err))]
      [else
       (define p (hash-ref r 'platform))
       (define g (hash-ref r 'gate))
       (define ok (hash-ref r 'ok))
       (define key (cons p g))
       (cond
         [(hash-has-key? seen key)
          (unless (equal? (hash-ref seen key) ok)
            (problem! (format "conflicting ~a/~a legs" p g)))]
         [else
          (hash-set! seen key ok)
          (set! legs (cons (hasheq 'platform p 'gate g 'ok ok) legs))])]))
  (define sorted-legs
    (sort legs
          (lambda (a b)
            (define pa (hash-ref a 'platform))
            (define pb (hash-ref b 'platform))
            (if (string=? pa pb)
                (string<? (hash-ref a 'gate) (hash-ref b 'gate))
                (string<? pa pb)))))
  (define ok?
    (and (null? problems)
         (pair? sorted-legs)
         (for/and ([l (in-list sorted-legs)])
           (hash-ref l 'ok))))
  (hasheq 'contract-version
          acceptance-contract-version
          'product
          acceptance-product
          'ok
          ok?
          'platforms
          (remove-duplicates (sort (map (lambda (l) (hash-ref l 'platform)) sorted-legs) string<?))
          'gates
          (remove-duplicates (sort (map (lambda (l) (hash-ref l 'gate)) sorted-legs) string<?))
          'legs
          sorted-legs
          'problems
          (reverse problems)))

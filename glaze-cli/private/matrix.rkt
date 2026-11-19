#lang racket/base

;; `raco glaze matrix <report.json>...` — fold per-platform acceptance
;; reports into the G4 cross-platform conformance matrix with a fail-closed
;; rollup (rivet `matrix` parity). Unreadable files and malformed envelopes
;; become problems, never silent passes.

(require json
         racket/format
         racket/string
         glaze/private/acceptance)

(provide matrix-command
         parse-matrix-opts)

(define (parse-matrix-opts args)
  (let loop ([args args]
             [opts (hasheq 'json #f 'out #f 'files '())])
    (cond
      [(null? args) (hash-update opts 'files reverse)]
      [(member (car args) '("--json" "-j")) (loop (cdr args) (hash-set opts 'json #t))]
      [(equal? (car args) "--out")
       (when (null? (cdr args))
         (error 'matrix "--out requires a file"))
       (loop (cddr args) (hash-set opts 'out (cadr args)))]
      [(string-prefix? (car args) "--out=")
       (loop (cdr args) (hash-set opts 'out (substring (car args) 6)))]
      [(string-prefix? (car args) "-") (error 'matrix "unknown option: ~a" (car args))]
      [else (loop (cdr args) (hash-update opts 'files (lambda (fs) (cons (car args) fs))))])))

(define (write-json-file path report)
  (call-with-output-file path (lambda (out) (write-json report out)) #:exists 'truncate))

(define (matrix-command rest)
  (define opts (parse-matrix-opts rest))
  (define files (hash-ref opts 'files))
  (when (null? files)
    (displayln "usage: raco glaze matrix <report.json>... [--json] [--out FILE]")
    (exit 1))
  (define-values (reports read-problems)
    (for/fold ([rs '()]
               [ps '()])
              ([f (in-list files)])
      (with-handlers ([exn:fail? (lambda (e)
                                   (values rs (cons (format "~a: ~a" f (exn-message e)) ps)))])
        (values (cons (call-with-input-file f read-json) rs) ps))))
  (define base (aggregate-matrix (reverse reports)))
  (define problems (append (reverse read-problems) (hash-ref base 'problems)))
  (define ok (and (null? problems) (hash-ref base 'ok)))
  (define matrix (hash-set (hash-set base 'problems problems) 'ok ok))
  (define out (hash-ref opts 'out))
  (when out
    (write-json-file out matrix))
  (cond
    [(hash-ref opts 'json)
     (write-json matrix)
     (newline)]
    [else
     (printf "Glaze acceptance matrix: ~a~n" (if ok "ok" "FAILED"))
     (printf "  platforms: ~a~n" (string-join (hash-ref matrix 'platforms) ", "))
     (printf "  gates: ~a~n" (string-join (hash-ref matrix 'gates) ", "))
     (for ([leg (in-list (hash-ref matrix 'legs))])
       (printf "  ~a/~a: ~a~n"
               (hash-ref leg 'platform)
               (hash-ref leg 'gate)
               (if (hash-ref leg 'ok) "ok" "FAILED")))
     (for ([p (in-list problems)])
       (printf "  problem: ~a~n" p))
     (when out
       (printf "  wrote ~a~n" out))])
  (if ok 0 1))

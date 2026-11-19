#lang racket/base

;; `raco glaze compliance [--json] [--out DIR]` — generate the CycloneDX
;; SBOM and third-party notices for the installed glaze dependency
;; closure and run the license audit. Exit 0 only when every component
;; carries an acceptable license; unknown and rejected licenses fail
;; closed so a release cannot ship an unreviewed dependency.

(require json
         racket/file
         racket/format
         racket/list
         racket/string
         glaze/private/compliance)

(provide compliance-command
         parse-compliance-opts)

(define (parse-compliance-opts rest)
  (let loop ([args rest]
             [out #f]
             [json? #f])
    (cond
      [(null? args) (values (or out ".") json?)]
      [(equal? (car args) "--json") (loop (cdr args) out #t)]
      [(and (equal? (car args) "--out") (pair? (cdr args))) (loop (cddr args) (cadr args) json?)]
      [else (error 'compliance "unexpected argument: ~a" (car args))])))

(define (compliance-command rest)
  (define-values (out json?) (parse-compliance-opts rest))
  (define components (dependency-closure '("glaze") package-metadata))
  (unless (for/or ([md (in-list components)])
            (and (equal? (hash-ref md 'name) "glaze") (not (hash-ref md 'missing #f))))
    (error 'compliance "the glaze package is not installed; run `raco glaze doctor`"))
  (define report (audit-report components))
  (make-directory* out)
  (define sbom-path (build-path out "glaze-sbom.cdx.json"))
  (define notices-path (build-path out "glaze-notices.txt"))
  (call-with-output-file sbom-path
                         #:exists 'replace
                         (lambda (o)
                           (write-json (sbom-document "glaze" components) o)
                           (newline o)))
  (call-with-output-file notices-path
                         #:exists 'replace
                         (lambda (o) (display (notices-text "glaze" components) o)))
  (cond
    [json?
     (write-json (hash-set (hash-set report 'sbom (path->string sbom-path))
                           'notices
                           (path->string notices-path)))
     (newline)]
    [else
     (printf "SBOM:    ~a\n" (path->string sbom-path))
     (printf "Notices: ~a\n" (path->string notices-path))
     (printf "License audit: ~a packages, ~a ok\n"
             (length components)
             (for/sum ([row (in-list (hash-ref report 'components))])
                      (if (equal? (hash-ref row 'verdict) "ok") 1 0)))
     (for ([problem (in-list (hash-ref report 'problems))])
       (printf "  - ~a\n" problem))
     (if (hash-ref report 'ok)
         (displayln "OK: all dependency licenses are acceptable")
         (displayln "FAIL: resolve the license problems above before releasing"))])
  (if (hash-ref report 'ok) 0 1))

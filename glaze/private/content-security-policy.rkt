#lang racket/base

(require racket/string)

(provide content-security-policy-headers)

;; Return immutable name/value strings without coupling policy validation
;; to an HTTP server or platform-specific response representation.
(define (content-security-policy-headers who enforced report-only)
  (define (policy-header name policy)
    (cond
      [(not policy) '()]
      [(and (string? policy)
            (not (string=? (string-trim policy) ""))
            (for/and ([ch (in-string policy)])
              (<= 32 (char->integer ch) 126)))
       (list (cons name (string->immutable-string policy)))]
      [else (raise-argument-error who "(or/c #f nonempty-printable-ASCII-policy)" policy)]))
  (append (policy-header "Content-Security-Policy" enforced)
          (policy-header "Content-Security-Policy-Report-Only" report-only)))

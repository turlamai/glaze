#lang racket/base

(require rackunit
         glaze/private/content-security-policy)

(test-case "CSP is opt-in and modes are independent"
  (check-equal? (content-security-policy-headers 'test #f #f) '())
  (check-equal? (content-security-policy-headers 'test "default-src 'self'" #f)
                '(("Content-Security-Policy" . "default-src 'self'")))
  (check-equal? (content-security-policy-headers 'test #f "script-src 'none'")
                '(("Content-Security-Policy-Report-Only" . "script-src 'none'")))
  (check-equal? (content-security-policy-headers 'test "default-src 'self'" "script-src 'none'")
                '(("Content-Security-Policy" . "default-src 'self'")
                  ("Content-Security-Policy-Report-Only" . "script-src 'none'"))))

(test-case "CSP rejects invalid response header values in either mode"
  (for ([invalid (in-list (list "" " " "x\r\ny" "x\ty" "x\u007fy" "x\u0080y" 42 #t))])
    (check-exn exn:fail:contract? (lambda () (content-security-policy-headers 'test invalid #f)))
    (check-exn exn:fail:contract? (lambda () (content-security-policy-headers 'test #f invalid)))))

(test-case "CSP takes an immutable snapshot of caller-owned strings"
  (define input (string-copy "script-src 'none'"))
  (define headers (content-security-policy-headers 'test input #f))
  (string-set! input 0 #\X)
  (check-equal? (cdar headers) "script-src 'none'")
  (check-true (immutable? (cdar headers))))

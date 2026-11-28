#lang racket/base

(require rackunit
         glaze/power)

(test-case "power capability reports availability without raising"
  (check-true (boolean? (power-supported?)))
  (check-true (or (not (power-diagnostic)) (string? (power-diagnostic)))))

(test-case "invalid input and foreign tokens are rejected"
  (check-exn exn:fail:contract? (lambda () (keep-awake-acquire! " ")))
  (check-exn exn:fail:contract? (lambda () (keep-awake-acquire! "test" #:kind 'invalid)))
  (check-false (keep-awake-token? #f))
  (check-false (keep-awake-release! #f))
  (check-false (keep-awake-release! 'unknown)))

(test-case "real assertions can be released exactly once when available"
  (define token (keep-awake-acquire! "Glaze power test"))
  (when token
    (dynamic-wind
     void
     (lambda ()
       (check-true (keep-awake-token? token))
       (check-true (keep-awake-release! token))
       (check-false (keep-awake-release! token)))
     (lambda () (keep-awake-release! token)))))

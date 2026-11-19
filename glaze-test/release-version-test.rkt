#lang racket/base

;; Regression tests for the release version preflight pure core. The alignment
;; rules from docs/RELEASING.md are exercised on already-read strings so they
;; need no installed package or filesystem: the two version forms must agree,
;; the changelog must carry the release, tags must match (RCs need --allow-rc),
;; and every carrier must mention the release. Argument parsing is guarded too.

(require rackunit
         glaze/private/release-version)

;; ---- normalized-racket-version -------------------------------------------

(check-equal? (normalized-racket-version "0.19.0") "0.19")
(check-equal? (normalized-racket-version "1.0.0") "1.0")
(check-equal? (normalized-racket-version "0.19.1") "0.19.1")
(check-equal? (normalized-racket-version "1.2.3") "1.2.3")
(check-equal? (normalized-racket-version "10.20.0") "10.20")
(check-false (normalized-racket-version "0.19"))
(check-false (normalized-racket-version "1.2.3.4"))
(check-false (normalized-racket-version "01.2.0"))
(check-false (normalized-racket-version "1.2.03"))
(check-false (normalized-racket-version "1.2"))
(check-false (normalized-racket-version #f))

;; ---- release-candidate-version? / tag-version ----------------------------

(check-true (release-candidate-version? "0.19.0" "0.19.0-rc.1"))
(check-true (release-candidate-version? "0.19.0" "0.19.0-rc.12"))
(check-false (release-candidate-version? "0.19.0" "0.19.0-rc.0"))
(check-false (release-candidate-version? "0.19.0" "0.19.0-beta.1"))
(check-false (release-candidate-version? "0.19.0" "0.19.0"))
(check-false (release-candidate-version? "0.19.0" "0.18.0-rc.1"))
(check-equal? (tag-version "v0.19.0") "0.19.0")
(check-equal? (tag-version "0.19.0") "0.19.0")
(check-equal? (tag-version "v1.0.0-rc.3") "1.0.0-rc.3")

;; ---- check-release-version: aligned metadata -----------------------------

(define aligned
  (check-release-version #:version "0.19"
                         #:release-version "0.19.0"
                         #:changelog "## 0.19.0 — 2026-11-19\nnotes\n"))
(check-true (hash-ref aligned 'ok))
(check-true (hash-ref aligned 'changelog-ok))
(check-equal? (hash-ref aligned 'problems) '())
(check-equal? (hash-ref aligned 'version) "0.19")
(check-equal? (hash-ref aligned 'release-version) "0.19.0")

;; A non-zero patch keeps three components in both forms.
(check-true
 (hash-ref (check-release-version #:version "0.19.1" #:release-version "0.19.1" #:changelog "0.19.1")
           'ok))

;; ---- check-release-version: version divergence ---------------------------

;; The Racket form must drop a trailing .0; keeping it is a mismatch.
(define divergent
  (check-release-version #:version "0.19.0" #:release-version "0.19.0" #:changelog "0.19.0"))
(check-false (hash-ref divergent 'ok))
(check-not-false
 (member "version 0.19.0 does not match release-version 0.19.0 (expected Racket form 0.19)"
         (hash-ref divergent 'problems)))

(check-false
 (hash-ref (check-release-version #:version "0.18" #:release-version "0.19.0" #:changelog "0.19.0")
           'ok))

;; Missing or malformed bindings fail closed.
(check-false (hash-ref (check-release-version #:version "0.19" #:release-version #f #:changelog "x")
                       'ok))
(check-false
 (hash-ref (check-release-version #:version #f #:release-version "0.19.0" #:changelog "0.19.0") 'ok))
(check-false
 (hash-ref (check-release-version #:version "0.19" #:release-version "0.19" #:changelog "0.19") 'ok))

;; ---- check-release-version: changelog carrier ----------------------------

(check-false
 (hash-ref (check-release-version #:version "0.19" #:release-version "0.19.0" #:changelog #f) 'ok))
(define no-entry
  (check-release-version #:version "0.19" #:release-version "0.19.0" #:changelog "## 0.18.0\nold\n"))
(check-false (hash-ref no-entry 'ok))
(check-false (hash-ref no-entry 'changelog-ok))

;; ---- check-release-version: tag matching ---------------------------------

(check-true (hash-ref (check-release-version #:version "0.19"
                                             #:release-version "0.19.0"
                                             #:tag "v0.19.0"
                                             #:changelog "0.19.0")
                      'ok))
(check-false (hash-ref (check-release-version #:version "0.19"
                                              #:release-version "0.19.0"
                                              #:tag "v0.18.0"
                                              #:changelog "0.19.0")
                       'ok))
;; RC tags need --allow-rc, and only positive rc.N counts.
(check-false (hash-ref (check-release-version #:version "0.19"
                                              #:release-version "0.19.0"
                                              #:tag "v0.19.0-rc.1"
                                              #:changelog "0.19.0")
                       'ok))
(check-true (hash-ref (check-release-version #:version "0.19"
                                             #:release-version "0.19.0"
                                             #:tag "v0.19.0-rc.1"
                                             #:allow-rc? #t
                                             #:changelog "0.19.0")
                      'ok))
(check-false (hash-ref (check-release-version #:version "0.19"
                                              #:release-version "0.19.0"
                                              #:tag "v0.19.0-rc.0"
                                              #:allow-rc? #t
                                              #:changelog "0.19.0")
                       'ok))

;; ---- check-release-version: declared carriers ----------------------------

(define with-carrier
  (check-release-version #:version "0.19"
                         #:release-version "0.19.0"
                         #:changelog "0.19.0"
                         #:carriers (list (cons "README.md" "version 0.19.0 here"))))
(check-true (hash-ref with-carrier 'ok))
(check-true (hash-ref (car (hash-ref with-carrier 'carriers)) 'contains-version))

(define missing-carrier
  (check-release-version #:version "0.19"
                         #:release-version "0.19.0"
                         #:changelog "0.19.0"
                         #:carriers (list (cons "ABSENT.md" #f))))
(check-false (hash-ref missing-carrier 'ok))
(check-false (hash-ref (car (hash-ref missing-carrier 'carriers)) 'contains-version))

(check-false (hash-ref (check-release-version #:version "0.19"
                                              #:release-version "0.19.0"
                                              #:changelog "0.19.0"
                                              #:carriers (list (cons "STALE.md" "version 0.18.0")))
                       'ok))

;; ---- argument parsing ----------------------------------------------------

(define-values (parsed-tag parsed-options)
  (parse-release-version-arguments
   '("v0.19.0" "--json" "--allow-rc" "--carrier" "a.md" "--carrier" "b.md" "--info" "pkg/info.rkt")))
(check-equal? parsed-tag "v0.19.0")
(check-true (hash-ref parsed-options 'json?))
(check-true (hash-ref parsed-options 'allow-rc?))
(check-equal? (hash-ref parsed-options 'info) "pkg/info.rkt")
;; carriers are accumulated then reversed by the caller; here newest first.
(check-equal? (hash-ref parsed-options 'carriers) '("b.md" "a.md"))

(define-values (no-tag no-options) (parse-release-version-arguments '("--json")))
(check-false no-tag)
(check-true (hash-ref no-options 'json?))

(check-exn exn:fail? (lambda () (parse-release-version-arguments '("--bogus"))))
(check-exn exn:fail? (lambda () (parse-release-version-arguments '("v1.0.0" "v2.0.0"))))
(check-exn exn:fail? (lambda () (parse-release-version-arguments '("--info" "a" "--info" "b"))))
(check-exn exn:fail? (lambda () (parse-release-version-arguments '("--json" "--json"))))

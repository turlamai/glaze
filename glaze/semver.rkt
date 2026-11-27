#lang racket/base

(require keel/semver
         racket/string)

(provide semver?
         semver-compare
         semver<?
         semver<=?
         semver=?
         semver>=?
         semver>?
         valid-update-channel?
         channel-accepts-version?)

;; Keel owns SemVer validation and precedence. Glaze owns channel policy.
(define (valid-update-channel? value)
  (and (memq value '(stable beta dev)) #t))

(define (channel-accepts-version? channel value)
  (unless (valid-update-channel? channel)
    (raise-argument-error 'channel-accepts-version? "'stable, 'beta, or 'dev" channel))
  (unless (semver? value)
    (raise-argument-error 'channel-accepts-version? "SemVer 2.0 version string" value))
  ;; Only inspect prerelease identifiers, never build metadata.
  (define core (car (string-split value "+")))
  (define prerelease (regexp-match #px"^[0-9]+\\.[0-9]+\\.[0-9]+-(.+)$" core))
  (case channel
    [(stable) (not prerelease)]
    [(beta)
     (or (not prerelease)
         (for/or ([part (in-list (string-split (cadr prerelease) "."))])
           (regexp-match? #px"(?i:^beta(?:[.-]|$))" part)))]
    [(dev) #t]))

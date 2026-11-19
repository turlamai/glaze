#lang racket/base

;; Release version preflight — the glaze analogue of rivet's
;; `check-release-version` command. docs/RELEASING.md defines two equivalent
;; version forms: info.rkt `version` is the canonical Racket package version
;; ("0.19"), while `release-version`, Git tags, and the changelog use
;; three-component SemVer ("0.19.0"). Before a release is tagged these must
;; agree, the changelog must carry the release, and any declared carrier file
;; must mention it. The pure functions here operate on already-read strings so
;; the alignment rules are regression-testable without touching the filesystem;
;; the CLI shell reads info.rkt through setup/getinfo and the carrier files.
;;
;; Everything fails closed: a missing binding, a malformed SemVer, a divergent
;; Racket version, an absent changelog entry, a mismatched tag, or a carrier
;; that does not mention the release all produce a problem and ok = #f, so a
;; release cannot be tagged from inconsistent metadata.

(require racket/list
         racket/match
         racket/string)

(provide parse-release-version-arguments
         normalized-racket-version
         release-candidate-version?
         tag-version
         check-release-version)

;; ---- argument parsing -----------------------------------------------------

;; [ <tag> ] [ --info FILE ] [ --carrier FILE ]... [ --allow-rc ] [ --json ]
;; The tag is the only positional argument. --carrier is repeatable; every
;; other option may appear at most once. Unknown flags and a second positional
;; are rejected so a typo cannot silently skip a check.
(define (parse-release-version-arguments arguments)
  (let loop ([remaining arguments]
             [options (hasheq)]
             [tag #f])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'check-release-version (format "~a may be specified only once" key))
          (loop tail (hash-set options key value) tag)))
    (match remaining
      ['() (values tag options)]
      [(list* "--info" value tail) (with 'info tail value)]
      [(list* "--carrier" value tail)
       (loop tail (hash-update options 'carriers (lambda (vs) (cons value vs)) '()) tag)]
      [(list* "--allow-rc" tail) (with 'allow-rc? tail #t)]
      [(list* "--json" tail) (with 'json? tail #t)]
      [(cons argument tail)
       (cond
         [(string-prefix? argument "--")
          (raise-arguments-error 'check-release-version "unknown argument" "argument" argument)]
         [tag
          (raise-arguments-error 'check-release-version
                                 "only one release tag may be given"
                                 "values"
                                 (list tag argument))]
         [else (loop tail options argument)])])))

;; ---- version forms --------------------------------------------------------

;; Three-component SemVer with no leading zeros. "X.Y.0" normalizes to the
;; Racket form "X.Y" (Racket rejects a trailing ".0" component); a non-zero
;; patch keeps all three components. Anything that is not exactly three
;; numeric components yields #f, so a malformed release-version is reported
;; rather than silently normalized.
(define (normalized-racket-version release-version)
  (and (string? release-version)
       (match (regexp-match #px"^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"
                            release-version)
         [(list _ major minor "0") (string-append major "." minor)]
         [(list _ major minor patch) (string-append major "." minor "." patch)]
         [_ #f])))

;; A release candidate tag is the release version followed by "-rc.N" with a
;; positive integer N (rc.1, rc.2, ...). rc.0 and other suffixes are not RCs.
(define (release-candidate-version? version candidate)
  (and (string? version)
       (string? candidate)
       (regexp-match? (pregexp (format "^~a-rc\\.[1-9][0-9]*$" (regexp-quote version))) candidate)))

;; Git tags are conventionally prefixed with "v"; accept both forms.
(define (tag-version tag)
  (if (string-prefix? tag "v")
      (substring tag 1)
      tag))

;; ---- alignment report -----------------------------------------------------

;; Inputs are already-read values: the two info.rkt bindings, an optional tag,
;; the changelog text (#f when the file is absent), and an ordered list of
;; (path . text-or-#f) carrier pairs. The result is a machine-readable report
;; with ok, an ordered problem list, and the per-carrier evidence.
(define (check-release-version #:version version
                               #:release-version release-version
                               #:tag [tag #f]
                               #:allow-rc? [allow-rc? #f]
                               #:changelog [changelog #f]
                               #:carriers [carriers '()])
  (define problems '())
  (define (problem! fmt . args)
    (set! problems (cons (apply format fmt args) problems)))
  (define expected (normalized-racket-version release-version))
  (cond
    [(not (string? release-version)) (problem! "info.rkt is missing the release-version binding")]
    [(not expected)
     (problem! "release-version ~a is not three-component SemVer (MAJOR.MINOR.PATCH)"
               release-version)])
  (cond
    [(not (string? version)) (problem! "info.rkt is missing the version binding")]
    [(and expected (not (string=? version expected)))
     (problem! "version ~a does not match release-version ~a (expected Racket form ~a)"
               version
               release-version
               expected)])
  (define changelog-ok
    (cond
      [(not changelog)
       (problem! "CHANGELOG.md is missing")
       #f]
      [(not (and (string? release-version) (string-contains? changelog release-version)))
       (problem! "CHANGELOG.md does not contain release-version ~a" release-version)
       #f]
      [else #t]))
  (define tag-value (and tag (tag-version tag)))
  (when tag-value
    (define acceptable?
      (or (and (string? release-version) (string=? tag-value release-version))
          (and allow-rc? (release-candidate-version? release-version tag-value))))
    (unless acceptable?
      (problem! (if allow-rc?
                    "the tag must be v<release-version> or v<release-version>-rc.N"
                    "the tag must be v<release-version> (pass --allow-rc for release candidates)"))))
  (define carrier-rows
    (for/list ([carrier (in-list carriers)])
      (define path (car carrier))
      (define text (cdr carrier))
      (define contains?
        (and (string? text)
             (string? release-version)
             (if (string-contains? text release-version) #t #f)))
      (cond
        [(not text) (problem! "carrier file ~a does not exist" path)]
        [(not contains?)
         (problem! "carrier file ~a does not contain release-version ~a" path release-version)])
      (hasheq 'path path 'contains-version contains?)))
  (hasheq 'ok
          (null? problems)
          'problems
          (reverse problems)
          'version
          version
          'release-version
          release-version
          'tag
          tag-value
          'changelog-ok
          changelog-ok
          'carriers
          carrier-rows))

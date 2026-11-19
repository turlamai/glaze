#lang racket/base

;; Offline release-asset gate — the glaze analogue of rivet's
;; `verify-release-assets` command. Authenticating a signed update manifest is
;; necessary but insufficient: a feed may still point to a missing, renamed, or
;; mutated installer. This command checks the exact files that are about to be
;; published against the signed manifest, with no network access, update
;; installation, or private signing key. It complements `check-release-version`
;; (which validates version metadata before a tag exists): this gate validates
;; the real assets before they are published under that tag.
;;
;; The pure functions here operate on an already-verified update-manifest and a
;; table of pre-read file facts (name -> exists?/symlink?/size/sha256), so every
;; alignment rule is regression-testable without touching the filesystem or
;; performing Ed25519 verification. The CLI shell authenticates the manifest
;; through glaze/update and gathers the file facts from the release directory.
;;
;; Everything fails closed: a mutable base URL, a GitHub tag that diverges from
;; the signed version, an unsafe asset filename, an installer/extension
;; mismatch, a missing or symlinked asset, a size or SHA-256 mismatch, a
;; duplicated file, or a missing required target all produce a problem and
;; ok = #f, so an inconsistent release cannot be published.

(require racket/list
         racket/match
         racket/string
         "../update.rkt")

(provide parse-verify-release-assets-arguments
         parse-release-target
         installer-extension
         release-base-url-problems
         github-release-tag
         asset-name-for-url
         check-release-assets)

;; ---- installer kinds ------------------------------------------------------

;; glaze records the installer kind as a symbol on each update-artifact. Map the
;; kinds glaze builds to their canonical filename extension; an unknown kind
;; yields #f and skips the extension check (glaze does not constrain the
;; installer field to a fixed enumeration), while every other gate still applies.
(define (installer-extension installer)
  (case installer
    [(exe) ".exe"]
    [(msi) ".msi"]
    [(zip) ".zip"]
    [(dmg) ".dmg"]
    [(appimage) ".AppImage"]
    [(deb) ".deb"]
    [(rpm) ".rpm"]
    [(pkg) ".pkg"]
    [(tar.gz) ".tar.gz"]
    [else #f]))

;; ---- release base URL -----------------------------------------------------

;; The base URL must be an immutable HTTPS source. GitHub's moving
;; releases/latest/download alias is NOT immutable: every verified payload URL
;; must be pinned to its release tag. Independent HTTPS feeds are accepted with
;; a path and no query/fragment.
(define (release-base-url-problems base-url)
  (define problems '())
  (define (problem! fmt . args)
    (set! problems (cons (apply format fmt args) problems)))
  (cond
    [(not (string? base-url)) (problem! "release base URL must be a string")]
    [(not (regexp-match? #px"^https://[^/]+/.+" base-url))
     (problem! "release base URL must be an HTTPS URL with a path")]
    [(regexp-match? #px"[?#]" base-url)
     (problem! "release base URL must not contain a query or fragment")]
    [(and (regexp-match? #px"^https://github[.]com/" base-url)
          (not (and (regexp-match? #px"^https://github[.]com/[^/]+/[^/]+/releases/download/[^/]+$"
                                   base-url)
                    (not (regexp-match? #px"/releases/download/latest$" base-url)))))
     (problem!
      "GitHub release base URL must pin an immutable tag (.../releases/download/<tag>, not latest)")])
  (reverse problems))

;; The tag segment of a GitHub releases/download URL, or #f for other feeds.
(define (github-release-tag base-url)
  (and (string? base-url)
       (match (regexp-match #px"/releases/download/([^/]+)$" base-url)
         [(list _ tag) tag]
         [_ #f])))

;; Extract the literal single-segment filename a signed URL points at under the
;; release base. Do not decode URL escapes or let a signed path escape the
;; release directory; anything ambiguous yields #f and is reported.
(define (asset-name-for-url url base-url)
  (and (string? url)
       (string? base-url)
       (let ([prefix (string-append (string-trim base-url "/" #:right? #t) "/")])
         (and (string-prefix? url prefix)
              (let ([name (substring url (string-length prefix))])
                (and (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._+-]*$" name)
                     (not (member name '("." "..")))
                     (not (string-contains? name ".."))
                     name))))))

;; ---- required targets -----------------------------------------------------

;; glaze artifacts carry platform/architecture/installer (no component tag), so
;; a required target is the three-part form platform:arch:installer.
(define (parse-release-target value)
  (define parts (map string->symbol (string-split value ":")))
  (unless (and (= (length parts) 3)
               (memq (first parts) '(windows macos linux))
               (memq (second parts) '(x64 arm64))
               (installer-extension (third parts)))
    (raise-arguments-error
     'verify-release-assets
     "--require expects platform:arch:installer (windows|macos|linux : x64|arm64 : a known installer kind)"
     "value"
     value))
  parts)

;; ---- argument parsing -----------------------------------------------------

;; <manifest> <release-dir> <public-key> --base-url URL [ --key-id ID ]
;; [ --application-id ID ] [ --require TARGET ]... [ --json ]
;; The three positionals and --base-url are required. --require is repeatable;
;; every other option may appear at most once. Unknown flags and extra
;; positionals are rejected so a typo cannot silently skip a gate.
(define (parse-verify-release-assets-arguments arguments)
  (let loop ([remaining arguments]
             [options (hasheq)]
             [positionals '()]
             [required-targets '()])
    (define (with key tail value)
      (if (hash-has-key? options key)
          (raise-arguments-error 'verify-release-assets (format "~a may be specified only once" key))
          (loop tail (hash-set options key value) positionals required-targets)))
    (match remaining
      ['()
       (define pos (reverse positionals))
       (unless (= (length pos) 3)
         (raise-arguments-error 'verify-release-assets
                                "expected <manifest> <release-dir> <public-key>"
                                "given"
                                pos))
       (unless (hash-has-key? options 'base-url)
         (raise-arguments-error 'verify-release-assets
                                "required option is missing"
                                "option"
                                "--base-url"))
       (values (first pos)
               (second pos)
               (third pos)
               (hash-set options 'required-targets (reverse required-targets)))]
      [(list* "--base-url" value tail) (with 'base-url tail value)]
      [(list* "--key-id" value tail) (with 'key-id tail value)]
      [(list* "--application-id" value tail) (with 'application-id tail value)]
      [(list* "--require" value tail)
       (loop tail options positionals (cons (parse-release-target value) required-targets))]
      [(list* "--json" tail) (with 'json? tail #t)]
      [(cons argument tail)
       (if (string-prefix? argument "--")
           (raise-arguments-error 'verify-release-assets "unknown argument" "argument" argument)
           (loop tail options (cons argument positionals) required-targets))])))

;; ---- alignment report -----------------------------------------------------

;; Inputs are already-read values: a verified update-manifest, the immutable
;; release base URL, and a table mapping each asset filename to its file facts
;; (hasheq 'exists? 'symlink? 'size 'sha256). The table must use equal? hashing
;; (e.g. for/hash), since names are looked up as freshly extracted strings. The
;; result is a machine-readable, JSON-friendly report with ok, an ordered
;; problem list, per-asset evidence, and any missing required targets.
(define (check-release-assets manifest
                              base-url
                              asset-facts
                              #:application-id [application-id #f]
                              #:required-targets [required-targets '()])
  (define problems '())
  (define (problem! fmt . args)
    (set! problems (cons (apply format fmt args) problems)))
  (for ([p (in-list (release-base-url-problems base-url))])
    (problem! "~a" p))
  (define version (update-manifest-version manifest))
  (define gh-tag (github-release-tag base-url))
  (when gh-tag
    (define expected (string-append "v" version))
    (unless (string=? gh-tag expected)
      (problem! "GitHub release tag ~a does not match signed manifest version (expected ~a)"
                gh-tag
                expected)))
  (when (and application-id (not (equal? application-id (update-manifest-application-id manifest))))
    (problem! "signed application identity ~a does not match expected ~a"
              (update-manifest-application-id manifest)
              application-id))
  (define artifacts (update-manifest-artifacts manifest))
  (define asset-rows
    (for/list ([artifact (in-list artifacts)])
      (define url (update-artifact-url artifact))
      (define name (asset-name-for-url url base-url))
      (define installer (update-artifact-installer artifact))
      (define asset-problems '())
      (define (aproblem! fmt . args)
        (set! asset-problems (cons (apply format fmt args) asset-problems)))
      (cond
        [(not name)
         (aproblem! "signed asset URL ~a is not a safe single-segment file under the release base"
                    url)]
        [else
         (define ext (installer-extension installer))
         (when (and ext (not (string-suffix? (string-downcase name) (string-downcase ext))))
           (aproblem! "asset ~a does not match installer ~a (expected extension ~a)"
                      name
                      installer
                      ext))
         (define facts (hash-ref asset-facts name #f))
         (cond
           [(not facts) (aproblem! "signed release asset ~a is missing" name)]
           [(hash-ref facts 'symlink? #f)
            (aproblem! "release asset ~a must be a regular file, not a symlink" name)]
           [(not (hash-ref facts 'exists? #f)) (aproblem! "signed release asset ~a is missing" name)]
           [else
            (define actual-size (hash-ref facts 'size -1))
            (unless (= actual-size (update-artifact-size artifact))
              (aproblem! "release asset ~a size mismatch (expected ~a, actual ~a)"
                         name
                         (update-artifact-size artifact)
                         actual-size))
            (unless (string-ci=? (or (hash-ref facts 'sha256 "") "")
                                 (update-artifact-sha256 artifact))
              (aproblem! "release asset ~a SHA-256 does not match the signed manifest" name))])])
      (for ([p (in-list (reverse asset-problems))])
        (problem! "~a" p))
      (hasheq 'name
              (or name url)
              'platform
              (symbol->string (update-artifact-platform artifact))
              'architecture
              (symbol->string (update-artifact-architecture artifact))
              'installer
              (symbol->string installer)
              'ok
              (null? asset-problems)
              'problems
              (reverse asset-problems))))
  ;; One physical file cannot stand in for distinct installer identities.
  (define extracted-names
    (for/list ([artifact (in-list artifacts)])
      (asset-name-for-url (update-artifact-url artifact) base-url)))
  (define duplicate (check-duplicates (filter string? extracted-names)))
  (when duplicate
    (problem! "multiple signed artifact identities point to the same file ~a" duplicate))
  (define available-targets
    (for/list ([artifact (in-list artifacts)])
      (list (update-artifact-platform artifact)
            (update-artifact-architecture artifact)
            (update-artifact-installer artifact))))
  (define missing-targets
    (for/list ([target (in-list required-targets)]
               #:unless (member target available-targets equal?))
      target))
  (for ([target (in-list missing-targets)])
    (problem! "required release target ~a is missing from the signed manifest"
              (string-join (map symbol->string target) ":")))
  (hasheq 'ok
          (null? problems)
          'problems
          (reverse problems)
          'version
          version
          'application-id
          (update-manifest-application-id manifest)
          'base-url
          base-url
          'assets
          asset-rows
          'required-targets-missing
          (map (lambda (target) (string-join (map symbol->string target) ":")) missing-targets)))

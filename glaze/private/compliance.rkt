#lang racket/base

;; Release compliance core — the glaze analogue of rivet's `compliance`
;; command (SBOM + third-party notices + license audit). The pure
;; functions here operate on package-metadata hashes so the closure,
;; verdicts, and documents are regression-testable without an installed
;; package table; `package-metadata` is the thin IO shell that reads the
;; real table through pkg/lib and setup/getinfo.
;;
;; Metadata hash shape:
;;   name         string
;;   version      string or #f
;;   license      symbol, string, SPDX expression list, or #f
;;   deps         info.rkt deps list (entries: string or (name #:version v))
;;   authors      list or #f
;;   license-text string or #f (found LICENSE/COPYING file content)
;;   missing      #t when the package is declared but not installed

(require racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         pkg/lib
         setup/getinfo)

(provide dep-entry-name
         dependency-closure
         license-verdict
         license-expression-string
         sbom-document
         notices-text
         audit-report
         package-scope
         package-metadata)

;; ---- dependency closure -------------------------------------------------

;; info.rkt dep entries are plain strings or (name #:version floor) lists;
;; platform-conditional entries (name #:platform spec) only belong to the
;; closure when spec matches the running platform, so a Windows install
;; does not pull in the linux/macos natipkg variants as missing rows.
(define (entry-platform entry)
  (let loop ([xs (cdr entry)])
    (cond
      [(null? xs) #f]
      [(and (pair? xs) (eq? (car xs) '#:platform) (pair? (cdr xs))) (cadr xs)]
      [else (loop (cdr xs))])))

;; A #:platform spec matches when its path elements are a prefix of the
;; running platform's system-library-subpath (e.g. "win32\\x86_64" matches
;; "win32\\x86_64\\cs"; "x86_64-linux-natipkg" does not match win32).
(define (platform-matches? spec)
  (define spec-str
    (cond
      [(string? spec) spec]
      [(symbol? spec) (symbol->string spec)]
      [(path? spec) (path->string spec)]
      [else (format "~a" spec)]))
  (let loop ([s (explode-path (string->path spec-str))]
             [c (explode-path (system-library-subpath))])
    (cond
      [(null? s) #t]
      [(null? c) #f]
      [(equal? (car s) (car c)) (loop (cdr s) (cdr c))]
      [else #f])))

(define (dep-entry-name entry)
  (cond
    [(string? entry) entry]
    [(and (pair? entry) (string? (car entry)))
     (define platform (entry-platform entry))
     (if (and platform (not (platform-matches? platform)))
         #f
         (car entry))]
    [else #f]))

;; Breadth-first transitive closure over `lookup` (name -> metadata or #f).
;; Declared-but-uninstalled packages stay in the closure as missing rows so
;; the audit reports them instead of silently shrinking the SBOM.
(define (dependency-closure roots lookup)
  (define seen (make-hash))
  (define collected '())
  (define (visit name)
    (unless (hash-ref seen name #f)
      (hash-set! seen name #t)
      (define md (lookup name))
      (set! collected (cons (or md (hasheq 'name name 'missing #t)) collected))
      (when md
        (for ([entry (in-list (hash-ref md 'deps '()))])
          (define dep (dep-entry-name entry))
          (when dep
            (visit dep))))))
  (for ([root (in-list roots)])
    (visit root))
  (sort (reverse collected) (lambda (a b) (string<? (hash-ref a 'name) (hash-ref b 'name)))))

;; ---- license audit ------------------------------------------------------

;; Permissive and weak-copyleft licenses compatible with distributing a
;; MIT-licensed framework and its packaged apps. Strong copyleft and
;; source-available licenses are rejected: they would impose obligations
;; the MIT release cannot carry.
(define permissive-licenses
  '("MIT" "Apache-2.0"
          "BSD-2-Clause"
          "BSD-3-Clause"
          "ISC"
          "0BSD"
          "Unlicense"
          "CC0-1.0"
          "Zlib"
          "BSL-1.0"
          "MPL-2.0"
          "blessing"
          "LGPL-2.1-only"
          "LGPL-2.1-or-later"
          "LGPL-3.0-only"
          "LGPL-3.0-or-later"
          ;; The OpenSSL license (Apache-1.1 style with an advertising
          ;; clause; permissive, not copyleft). Racket's own natipkgs ship
          ;; under "(Apache-2.0 OR MIT) AND OpenSSL", so a standard Racket
          ;; installation fails the audit without it. "OpenSSL" is SPDX's
          ;; deprecated identifier for the same license, kept as an alias.
          "OpenSSL-standalone"
          "OpenSSL"))

(define rejected-licenses
  '("GPL-2.0-only" "GPL-2.0-or-later"
                   "GPL-3.0-only"
                   "GPL-3.0-or-later"
                   "AGPL-3.0-only"
                   "AGPL-3.0-or-later"
                   "SSPL-1.0"
                   "BUSL-1.1"))

;; SPDX license identifiers are matched case-insensitively: the canonical
;; list uses "BSD-3-Clause" but distribution metadata in the wild writes
;; "BSD-3-clause" (e.g. the macOS Racket natipkg), and "apache-2.0" / "MIT"
;; variants are equally valid. Case folding never widens the gate — a
;; rejected or genuinely unknown identifier stays rejected / unknown.
(define (atom-verdict id)
  (cond
    [(member id permissive-licenses string-ci=?) 'ok]
    [(member id rejected-licenses string-ci=?) 'rejected]
    [else 'unknown]))

(define (expression-parts lic)
  (filter (lambda (x) (not (memq x '(OR AND)))) lic))

;; SPDX-style expressions: (A OR B) is satisfied by any ok branch;
;; (A AND B) requires every branch ok. Unknown atoms fail closed.
(define (license-verdict lic)
  (cond
    [(symbol? lic) (atom-verdict (symbol->string lic))]
    [(string? lic) (atom-verdict lic)]
    [(and (list? lic) (memq 'OR lic))
     (define verdicts (map license-verdict (expression-parts lic)))
     (cond
       [(memq 'ok verdicts) 'ok]
       [(and (pair? verdicts)
             (for/and ([v (in-list verdicts)])
               (eq? v 'rejected)))
        'rejected]
       [else 'unknown])]
    [(and (list? lic) (memq 'AND lic))
     (define verdicts (map license-verdict (expression-parts lic)))
     (cond
       [(memq 'rejected verdicts) 'rejected]
       [(and (pair? verdicts)
             (for/and ([v (in-list verdicts)])
               (eq? v 'ok)))
        'ok]
       [else 'unknown])]
    [else 'unknown]))

(define (license-expression-string lic)
  (cond
    [(symbol? lic) (symbol->string lic)]
    [(string? lic) lic]
    [(and (list? lic) (pair? lic)) (string-join (map (lambda (x) (format "~a" x)) lic) " ")]
    [else #f]))

;; ---- CycloneDX SBOM -----------------------------------------------------

(define (component-jsexpr md)
  (define name (hash-ref md 'name))
  (define version (hash-ref md 'version #f))
  (define lic (hash-ref md 'license #f))
  (define base (hasheq 'type "library" 'name name))
  (define with-version
    (if version
        (hash-set base 'version (format "~a" version))
        base))
  (define with-purl
    (if version
        (hash-set with-version 'purl (format "pkg:racket/~a@~a" name version))
        with-version))
  (define effective-lic (or lic (and (inherits-distribution? md) distribution-license)))
  (cond
    [(hash-ref md 'missing #f)
     (hash-set with-purl 'description "declared dependency not installed; metadata unavailable")]
    [(license-expression-string effective-lic)
     =>
     (lambda (s)
       (define lic-entry
         (if (or (symbol? effective-lic) (string? effective-lic))
             (hasheq 'license (hasheq 'id s))
             (hasheq 'expression s)))
       (define with-lic (hash-set with-purl 'licenses (list lic-entry)))
       (if (and (not lic) (inherits-distribution? md))
           (hash-set with-lic 'description "license inherited from the Racket main distribution")
           with-lic))]
    [else with-purl]))

;; CycloneDX 1.5 document: the root package is metadata.component, every
;; other closure member is a component. No timestamp — the document is
;; deterministic for a given package table, so release diffs stay clean.
(define (sbom-document root-name components)
  (define root
    (or (findf (lambda (c) (equal? (hash-ref c 'name) root-name)) components)
        (hasheq 'name root-name)))
  (hasheq 'bomFormat
          "CycloneDX"
          'specVersion
          "1.5"
          'version
          1
          'metadata
          (hasheq 'component (component-jsexpr root))
          'components
          (map component-jsexpr
               (filter (lambda (c) (not (equal? (hash-ref c 'name) root-name))) components))))

;; ---- third-party notices ------------------------------------------------

(define (notices-text root-name components)
  (string-append
   (format "Third-party notices for ~a\n" root-name)
   "Generated by `raco glaze compliance`. This product includes the\n"
   "following Racket packages; their license terms apply to the\n"
   "corresponding components.\n\n"
   (string-join
    (for/list ([md (in-list components)])
      (string-append
       (format "== ~a ~a ==\n" (hash-ref md 'name) (or (hash-ref md 'version #f) "(version unknown)"))
       (format "License: ~a\n" (or (license-expression-string (hash-ref md 'license #f)) "unknown"))
       (let ([authors (hash-ref md 'authors #f)])
         (if (and (list? authors) (pair? authors))
             (format "Authors: ~a\n" (string-join (map (lambda (a) (format "~a" a)) authors) ", "))
             ""))
       (let ([text (hash-ref md 'license-text #f)])
         (if text
             (string-append "\n" text "\n")
             ""))))
    "\n")))

;; ---- audit report -------------------------------------------------------

;; The Racket main distribution is uniformly Apache-2.0 OR MIT. That covers
;; both installation-scope packages (racket-lib, the platform natipkg/db
;; binaries) and built-in core collections such as `racket` and `pkg-lib`
;; that have no package-table entry at all. Any component that is not a
;; user-scope catalog choice and declares no license inherits this baseline.
;; A user-scope dependency (glaze's actual third-party choices: keel,
;; ed25519, ...) with no declared license still fails closed as 'unknown,
;; and a declared license is always audited regardless of scope.
(define distribution-license '(Apache-2.0 OR MIT))

(define (inherits-distribution? md)
  (and (not (hash-ref md 'license #f)) (not (eq? (hash-ref md 'scope #f) 'user))))

(define (component-verdict md)
  (cond
    [(hash-ref md 'license #f)
     =>
     license-verdict]
    [(inherits-distribution? md) 'ok]
    [else 'unknown]))

(define (audit-report components)
  (define rows
    (for/list ([md (in-list components)])
      (hasheq 'name
              (hash-ref md 'name)
              'version
              (hash-ref md 'version #f)
              'license
              (or (license-expression-string (hash-ref md 'license #f))
                  (and (inherits-distribution? md) (license-expression-string distribution-license)))
              'verdict
              (symbol->string (component-verdict md)))))
  (define problems
    (for/list ([row (in-list rows)]
               #:when (not (equal? (hash-ref row 'verdict) "ok")))
      (format "~a: license ~a (~a)"
              (hash-ref row 'name)
              (or (hash-ref row 'license) "missing")
              (hash-ref row 'verdict))))
  (hasheq 'ok (null? problems) 'components rows 'problems problems))

;; ---- installed-package metadata (IO shell) ------------------------------

(define license-file-names
  '("LICENSE" "LICENSE.txt"
              "LICENSE.md"
              "COPYING"
              "COPYING.txt"
              "COPYING.LESSER"
              "LICENSE-MIT"
              "LICENSE-APACHE"))

;; Package scopes are stable for the process; read the table once, lazily.
;; installation scope = the Racket main distribution; user scope = catalog
;; dependencies the application actually chooses (glaze, keel, ed25519...).
(define scope-table
  (let ([cache #f])
    (lambda ()
      (unless cache
        (set! cache
              (with-handlers ([exn:fail? (lambda (_) (cons '() '()))])
                (cons (installed-pkg-names #:scope 'installation)
                      (installed-pkg-names #:scope 'user)))))
      cache)))

(define (package-scope name)
  (define table (scope-table))
  (cond
    [(member name (cdr table)) 'user]
    [(member name (car table)) 'installation]
    [else #f]))

(define (package-metadata name)
  (define dir0 (pkg-directory name))
  (and dir0
       (let ()
         (define dir (simplify-path dir0))
         (define gi
           (with-handlers ([exn:fail? (lambda (_) #f)])
             (get-info/full dir)))
         (define (field key
                        [default #f])
           (if gi
               (gi key (lambda () default))
               default))
         (define license-text
           (for/or ([fn (in-list license-file-names)])
             (define p (build-path dir fn))
             (and (file-exists? p)
                  (< (file-size p) 65536)
                  (with-handlers ([exn:fail? (lambda (_) #f)])
                    (file->string p)))))
         (hasheq 'name
                 name
                 'version
                 (field 'version)
                 'license
                 (field 'license)
                 'deps
                 (field 'deps
                        '())
                 'authors
                 (field 'pkg-authors)
                 'scope
                 (package-scope name)
                 'directory
                 (path->string dir)
                 'license-text
                 license-text))))

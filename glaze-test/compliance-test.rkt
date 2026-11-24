#lang racket/base

;; Regression tests for the compliance core: dependency closure, SPDX
;; license verdicts, CycloneDX SBOM shape, notices, and the audit report.
;; Pure functions run on synthetic metadata; one live smoke checks the
;; real installed package table when glaze is present.

(require racket/list
         racket/string
         glaze/private/compliance)

(module+ test
  (require rackunit)

  ;; ---- dep-entry-name ---------------------------------------------------
  (check-equal? (dep-entry-name "base") "base")
  (check-equal? (dep-entry-name '("keel" #:version "0.3.1")) "keel")
  (check-false (dep-entry-name '(("unix" "some-unix-only-pkg"))))
  (check-false (dep-entry-name 42))
  ;; platform-conditional deps for a foreign platform are skipped
  (check-false (dep-entry-name '("racket-x86_64-linux-natipkg-3" #:platform
                                                                 "definitely-not-this-platform")))

  ;; ---- dependency-closure -----------------------------------------------
  (define graph
    (hash "root"
          (hasheq 'name "root" 'deps '("a" "b"))
          "a"
          (hasheq 'name "a" 'deps '("c"))
          "b"
          (hasheq 'name "b" 'deps '("a"))
          "c"
          (hasheq 'name "c" 'deps '())))
  (define closure (dependency-closure '("root") (lambda (n) (hash-ref graph n #f))))
  (check-equal? (map (lambda (m) (hash-ref m 'name)) closure) '("a" "b" "c" "root"))
  ;; declared-but-uninstalled deps stay visible as missing rows
  (define with-missing
    (dependency-closure '("root")
                        (lambda (n)
                          (if (equal? n "c")
                              #f
                              (hash-ref graph n #f)))))
  (define missing-row (findf (lambda (m) (equal? (hash-ref m 'name) "c")) with-missing))
  (check-true (hash-ref missing-row 'missing #f))

  ;; ---- license-verdict --------------------------------------------------
  (check-equal? (license-verdict 'MIT) 'ok)
  (check-equal? (license-verdict "Apache-2.0") 'ok)
  (check-equal? (license-verdict 'GPL-3.0-only) 'rejected)
  (check-equal? (license-verdict "AGPL-3.0-or-later") 'rejected)
  (check-equal? (license-verdict "SomeProprietaryThing") 'unknown)
  (check-equal? (license-verdict #f) 'unknown)
  ;; Racket's own dual license: any ok branch satisfies an OR
  (check-equal? (license-verdict '(Apache-2.0 OR MIT)) 'ok)
  (check-equal? (license-verdict '(GPL-3.0-only OR MIT)) 'ok)
  (check-equal? (license-verdict '(GPL-3.0-only OR AGPL-3.0-only)) 'rejected)
  (check-equal? (license-verdict '(MIT AND Apache-2.0)) 'ok)
  (check-equal? (license-verdict '(MIT AND GPL-3.0-only)) 'rejected)
  (check-equal? (license-verdict '(MIT AND MysteryLicense)) 'unknown)
  ;; the SQLite public-domain blessing carried by the db natipkg packages
  (check-equal? (license-verdict "blessing") 'ok)
  (check-equal? (license-verdict '(Apache-2.0 OR MIT AND blessing)) 'ok)

  ;; ---- case-insensitive SPDX matching -----------------------------------
  ;; Distribution metadata writes SPDX ids in non-canonical case (the macOS
  ;; Racket natipkg uses "BSD-3-clause"); matching folds case without widening
  ;; the gate.
  (check-equal? (license-verdict "bsd-3-clause") 'ok)
  (check-equal? (license-verdict "BSD-3-CLAUSE") 'ok)
  (check-equal? (license-verdict 'bsd-2-clause) 'ok)
  (check-equal? (license-verdict "apache-2.0") 'ok)
  (check-equal? (license-verdict "ApAcHe-2.0") 'ok)
  (check-equal? (license-verdict 'mit) 'ok)
  (check-equal? (license-verdict "lgpl-2.1-or-later") 'ok)
  ;; rejected identifiers stay rejected in any case
  (check-equal? (license-verdict "gpl-3.0-only") 'rejected)
  (check-equal? (license-verdict "GPL-3.0-ONLY") 'rejected)
  (check-equal? (license-verdict 'agpl-3.0-or-later) 'rejected)
  (check-equal? (license-verdict '(MIT AND gpl-3.0-only)) 'rejected)
  ;; genuinely unknown identifiers still fail closed
  (check-equal? (license-verdict "bsd-3-clause-extra") 'unknown)
  (check-equal? (license-verdict "MIT-ISH") 'unknown)
  ;; the exact macOS Racket distribution compound expression that previously
  ;; failed closed because of the lowercase "BSD-3-clause" atom
  (check-equal? (license-verdict '((Apache-2.0 OR MIT) AND (BSD-3-clause AND Apache-2.0))) 'ok)
  (check-equal? (license-verdict '((Apache-2.0 OR MIT) AND (bsd-3-clause AND apache-2.0))) 'ok)
  (define macos-style-report
    (audit-report (list (hasheq 'name
                                "racket-x86_64-macosx-4"
                                'version
                                "9.3"
                                'license
                                '((Apache-2.0 OR MIT) AND (BSD-3-clause AND Apache-2.0))
                                'scope
                                'installation))))
  (check-true (hash-ref macos-style-report 'ok))
  (check-equal? (hash-ref macos-style-report 'problems) '())

  ;; ---- sbom-document ----------------------------------------------------
  (define components
    (list (hasheq 'name "root" 'version "1.0" 'license 'MIT)
          (hasheq 'name "dual" 'version "2.0" 'license '(Apache-2.0 OR MIT))
          (hasheq 'name "ghost" 'missing #t)))
  (define sbom (sbom-document "root" components))
  (check-equal? (hash-ref sbom 'bomFormat) "CycloneDX")
  (check-equal? (hash-ref sbom 'specVersion) "1.5")
  (check-equal? (hash-ref (hash-ref (hash-ref sbom 'metadata) 'component) 'name) "root")
  (define comps (hash-ref sbom 'components))
  (check-equal? (length comps) 2)
  (define dual (findf (lambda (c) (equal? (hash-ref c 'name) "dual")) comps))
  (check-equal? (hash-ref dual 'purl) "pkg:racket/dual@2.0")
  (check-equal? (hash-ref (car (hash-ref dual 'licenses)) 'expression) "Apache-2.0 OR MIT")
  (define root-comp (hash-ref (hash-ref sbom 'metadata) 'component))
  (check-equal? (hash-ref (hash-ref (car (hash-ref root-comp 'licenses)) 'license) 'id) "MIT")

  ;; ---- notices-text -----------------------------------------------------
  (define notices
    (notices-text "root"
                  (list (hasheq 'name
                                "root"
                                'version
                                "1.0"
                                'license
                                'MIT
                                'authors
                                '("alice")
                                'license-text
                                "MIT TEXT HERE"))))
  (check-true (string-contains? notices "root 1.0"))
  (check-true (string-contains? notices "License: MIT"))
  (check-true (string-contains? notices "alice"))
  (check-true (string-contains? notices "MIT TEXT HERE"))

  ;; ---- audit-report -----------------------------------------------------
  (define ok-report
    (audit-report (list (hasheq 'name "root" 'version "1.0" 'license 'MIT)
                        (hasheq 'name "dual" 'version "2.0" 'license '(Apache-2.0 OR MIT)))))
  (check-true (hash-ref ok-report 'ok))
  (check-equal? (hash-ref ok-report 'problems) '())
  ;; A stock Racket installation: its natipkgs declare "(Apache-2.0 OR MIT)
  ;; AND OpenSSL" with SPDX's deprecated identifier. The OpenSSL license is
  ;; permissive, so the audit accepts it under both its identifiers, while an
  ;; unknown identifier inside the same expression still fails closed.
  (define natipkg-report
    (audit-report (list (hasheq 'name
                                "racket-x86_64-linux-natipkg-3"
                                'version
                                "9.3"
                                'license
                                '((Apache-2.0 OR MIT) AND OpenSSL)
                                'scope
                                'installation))))
  (check-true (hash-ref natipkg-report 'ok))
  (check-equal? (hash-ref natipkg-report 'problems) '())
  (define openssl-report
    (audit-report
     (list (hasheq 'name "crypto-bindings" 'version "1.0" 'license '(MIT AND OpenSSL-standalone)))))
  (check-true (hash-ref openssl-report 'ok))
  (define unknown-in-report
    (audit-report (list (hasheq 'name
                                "mystery"
                                'version
                                "1.0"
                                'license
                                '((Apache-2.0 OR MIT) AND Proprietary-Terms)
                                'scope
                                'installation))))
  (check-false (hash-ref unknown-in-report 'ok))
  (define bad-report
    (audit-report (list (hasheq 'name "root" 'version "1.0" 'license 'MIT)
                        (hasheq 'name "gpl" 'version "1.0" 'license 'GPL-3.0-only)
                        (hasheq 'name "nolic" 'version "1.0" 'scope 'user)
                        (hasheq 'name "ghost" 'missing #t 'scope 'user))))
  (check-false (hash-ref bad-report 'ok))
  (check-equal? (length (hash-ref bad-report 'problems)) 3)
  ;; a declared rejected license fails even for a platform-scope package
  (define platform-gpl
    (audit-report
     (list (hasheq 'name "bad-plat" 'version "1.0" 'license 'GPL-3.0-only 'scope 'installation))))
  (check-false (hash-ref platform-gpl 'ok))

  ;; distribution inheritance: installation-scope packages with no declared
  ;; license inherit Apache-2.0 OR MIT; user-scope ones still fail closed.
  (define inherit-report
    (audit-report (list (hasheq 'name "racket-lib" 'version "9.3" 'scope 'installation))))
  (check-true (hash-ref inherit-report 'ok))
  (define mixed-report
    (audit-report (list (hasheq 'name "racket-lib" 'version "9.3" 'scope 'installation)
                        (hasheq 'name "mystery" 'version "1.0" 'scope 'user))))
  (check-false (hash-ref mixed-report 'ok))
  (check-equal? (length (hash-ref mixed-report 'problems)) 1)

  ;; ---- live smoke: the real installed package table ---------------------
  (define glaze-md (package-metadata "glaze"))
  (when glaze-md
    (check-equal? (hash-ref glaze-md 'name) "glaze")
    (check-true (string? (hash-ref glaze-md 'version)))
    (check-equal? (license-verdict (hash-ref glaze-md 'license)) 'ok)
    (define live-closure (dependency-closure '("glaze") package-metadata))
    (define live-names (map (lambda (m) (hash-ref m 'name)) live-closure))
    (check-not-false (member "keel" live-names))
    (check-not-false (member "ed25519" live-names))
    (define live-report (audit-report live-closure))
    (check-true (hash-ref live-report 'ok)
                (format "license audit problems: ~a" (hash-ref live-report 'problems)))))

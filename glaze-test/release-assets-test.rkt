#lang racket/base

;; Regression tests for the offline release-asset gate pure core. Every rule is
;; exercised on an already-verified update-manifest and a table of pre-read file
;; facts, so the tests need no filesystem, network, or Ed25519 signing: the base
;; URL must be immutable, a GitHub tag must match the signed version, each asset
;; filename must be safe and match its installer kind, the local file must exist
;; as a regular file with the signed size and SHA-256, no file may back two
;; identities, and every required target must be present. Argument parsing and
;; required-target parsing are guarded too.

(require racket/file
         racket/list
         racket/port
         rackunit
         glaze/update
         glaze/signing
         glaze/private/release-assets
         glaze-cli/private/release-assets)

;; String-keyed fact tables must use equal? hashing (the core looks names up
;; with freshly extracted strings), so build them with make-immutable-hash.
(define (table . kvs)
  (make-immutable-hash (let loop ([xs kvs])
                         (if (null? xs)
                             '()
                             (cons (cons (car xs) (cadr xs)) (loop (cddr xs)))))))

(define hex-a (make-string 64 #\a))
(define hex-b (make-string 64 #\b))
(define gh-base "https://github.com/o/r/releases/download/v1.2.0")

(define (artifact #:platform [platform 'windows]
                  #:arch [arch 'x64]
                  #:installer [installer 'msi]
                  #:name [name "App-1.2.0.msi"]
                  #:sha256 [sha256 hex-a]
                  #:size [size 100]
                  #:base [base gh-base])
  (update-artifact platform arch (string-append base "/" name) sha256 size installer '() #f))

(define (manifest artifacts #:version [version "1.2.0"] #:app-id [app-id "com.example.app"])
  (update-manifest app-id version 1 'stable "2026-01-01T00:00:00Z" "1.0.0" #f #t 100 artifacts))

(define (facts #:exists? [exists? #t]
               #:symlink? [symlink? #f]
               #:size [size 100]
               #:sha256 [sha256 hex-a])
  (hasheq 'exists? exists? 'symlink? symlink? 'size size 'sha256 sha256))

(define (facts-for artifacts)
  (for/hash ([a (in-list artifacts)])
    (define name (asset-name-for-url (update-artifact-url a) gh-base))
    (values name (facts #:size (update-artifact-size a) #:sha256 (update-artifact-sha256 a)))))

;; ---- installer-extension --------------------------------------------------

(check-equal? (installer-extension 'exe) ".exe")
(check-equal? (installer-extension 'msi) ".msi")
(check-equal? (installer-extension 'zip) ".zip")
(check-equal? (installer-extension 'dmg) ".dmg")
(check-equal? (installer-extension 'appimage) ".AppImage")
(check-equal? (installer-extension 'deb) ".deb")
(check-equal? (installer-extension 'rpm) ".rpm")
(check-equal? (installer-extension 'pkg) ".pkg")
(check-equal? (installer-extension 'tar.gz) ".tar.gz")
(check-false (installer-extension 'unknown))

;; ---- release-base-url-problems / github-release-tag ----------------------

(check-equal? (release-base-url-problems gh-base) '())
(check-equal? (release-base-url-problems "https://example.com/releases/v1.2.0") '())
(check-pred pair? (release-base-url-problems "https://github.com/o/r/releases/download/latest"))
(check-pred pair? (release-base-url-problems "http://github.com/o/r/releases/download/v1.2.0"))
(check-pred pair? (release-base-url-problems "https://github.com/o/r/releases/tag/v1.2.0"))
(check-pred pair? (release-base-url-problems "https://example.com/x?token=1"))
(check-pred pair? (release-base-url-problems "https://example.com/x#frag"))
(check-pred pair? (release-base-url-problems "https://example.com"))
(check-pred pair? (release-base-url-problems #f))
(check-equal? (github-release-tag gh-base) "v1.2.0")
(check-false (github-release-tag "https://example.com/releases/v1.2.0"))

;; ---- asset-name-for-url ---------------------------------------------------

(check-equal? (asset-name-for-url (string-append gh-base "/App.msi") gh-base) "App.msi")
(check-equal? (asset-name-for-url (string-append gh-base "/App.msi") (string-append gh-base "/"))
              "App.msi")
(check-false (asset-name-for-url "https://evil.com/App.msi" gh-base))
(check-false (asset-name-for-url (string-append gh-base "/../App.msi") gh-base))
(check-false (asset-name-for-url (string-append gh-base "/a..b.msi") gh-base))
(check-false (asset-name-for-url (string-append gh-base "/.hidden") gh-base))
(check-false (asset-name-for-url (string-append gh-base "/sub/App.msi") gh-base))
(check-false (asset-name-for-url (string-append gh-base "/App%2Emsi") gh-base))

;; ---- parse-release-target -------------------------------------------------

(check-equal? (parse-release-target "windows:x64:msi") '(windows x64 msi))
(check-equal? (parse-release-target "linux:arm64:appimage") '(linux arm64 appimage))
(check-exn exn:fail? (lambda () (parse-release-target "windows:x64")))
(check-exn exn:fail? (lambda () (parse-release-target "bsd:x64:msi")))
(check-exn exn:fail? (lambda () (parse-release-target "windows:x86:msi")))
(check-exn exn:fail? (lambda () (parse-release-target "windows:x64:bogus")))
(check-exn exn:fail? (lambda () (parse-release-target "windows:x64:msi:app")))

;; ---- parse-verify-release-assets-arguments -------------------------------

(define-values (m d k opts)
  (parse-verify-release-assets-arguments
   '("manifest.json" "release"
                     "public.pem"
                     "--base-url"
                     "https://github.com/o/r/releases/download/v1.2.0")))
(check-equal? m "manifest.json")
(check-equal? d "release")
(check-equal? k "public.pem")
(check-equal? (hash-ref opts 'base-url) gh-base)
(check-equal? (hash-ref opts 'required-targets) '())
(check-false (hash-ref opts 'json? #f))

(define-values (_m2 _d2 _k2 opts2)
  (parse-verify-release-assets-arguments `("m" "d"
                                               "k"
                                               "--base-url"
                                               ,gh-base
                                               "--key-id"
                                               "release-2026"
                                               "--application-id"
                                               "com.example.app"
                                               "--require"
                                               "windows:x64:msi"
                                               "--require"
                                               "linux:x64:appimage"
                                               "--json")))
(check-equal? (hash-ref opts2 'key-id) "release-2026")
(check-equal? (hash-ref opts2 'application-id) "com.example.app")
(check-true (hash-ref opts2 'json?))
(check-equal? (hash-ref opts2 'required-targets) '((windows x64 msi) (linux x64 appimage)))

(check-exn exn:fail? (lambda () (parse-verify-release-assets-arguments '("m" "d" "k"))))
(check-exn exn:fail?
           (lambda () (parse-verify-release-assets-arguments '("m" "d" "--base-url" gh-base))))
(check-exn exn:fail?
           (lambda ()
             (parse-verify-release-assets-arguments
              `("m" "d" "k" "--base-url" ,gh-base "--base-url" ,gh-base))))
(check-exn exn:fail?
           (lambda ()
             (parse-verify-release-assets-arguments
              `("m" "d" "k" "--base-url" ,gh-base "--json" "--json"))))
(check-exn exn:fail?
           (lambda ()
             (parse-verify-release-assets-arguments `("m" "d" "k" "extra" "--base-url" ,gh-base))))
(check-exn exn:fail?
           (lambda ()
             (parse-verify-release-assets-arguments `("m" "d" "k" "--base-url" ,gh-base "--bogus"))))

;; ---- check-release-assets: aligned ---------------------------------------

(define one (list (artifact)))
(define aligned (check-release-assets (manifest one) gh-base (facts-for one)))
(check-true (hash-ref aligned 'ok))
(check-equal? (hash-ref aligned 'problems) '())
(check-equal? (hash-ref aligned 'version) "1.2.0")
(check-equal? (hash-ref aligned 'application-id) "com.example.app")
(check-true (hash-ref (first (hash-ref aligned 'assets)) 'ok))
(check-equal? (hash-ref (first (hash-ref aligned 'assets)) 'platform) "windows")
(check-equal? (hash-ref aligned 'required-targets-missing) '())

;; ---- check-release-assets: base URL and tag ------------------------------

(check-false (hash-ref (check-release-assets (manifest one)
                                             "https://github.com/o/r/releases/download/latest"
                                             (facts-for one))
                       'ok))
(define wrong-tag
  (check-release-assets (manifest one)
                        "https://github.com/o/r/releases/download/v9.9.9"
                        (for/hash ([a (in-list one)])
                          (values "App-1.2.0.msi" (facts)))))
(check-false (hash-ref wrong-tag 'ok))

;; ---- check-release-assets: application identity --------------------------

(check-false
 (hash-ref
  (check-release-assets (manifest one) gh-base (facts-for one) #:application-id "com.other.app")
  'ok))
(check-true
 (hash-ref
  (check-release-assets (manifest one) gh-base (facts-for one) #:application-id "com.example.app")
  'ok))

;; ---- check-release-assets: per-asset gates -------------------------------

(define (asset-ok report)
  (hash-ref (first (hash-ref report 'assets)) 'ok))

(check-false (hash-ref (check-release-assets (manifest one) gh-base (hasheq)) 'ok))
(check-false (asset-ok (check-release-assets (manifest one)
                                             gh-base
                                             (table "App-1.2.0.msi" (facts #:exists? #f)))))
(check-false (asset-ok (check-release-assets (manifest one)
                                             gh-base
                                             (table "App-1.2.0.msi" (facts #:symlink? #t)))))
(check-false
 (asset-ok (check-release-assets (manifest one) gh-base (table "App-1.2.0.msi" (facts #:size 999)))))
(check-false (asset-ok (check-release-assets (manifest one)
                                             gh-base
                                             (table "App-1.2.0.msi" (facts #:sha256 hex-b)))))
;; installer/extension mismatch: an msi identity pointing at a .zip file.
(define zip-named (list (artifact #:name "App-1.2.0.zip")))
(check-false
 (asset-ok (check-release-assets (manifest zip-named) gh-base (table "App-1.2.0.zip" (facts)))))
;; case-insensitive extension match for AppImage.
(define appimage (list (artifact #:platform 'linux #:installer 'appimage #:name "App.AppImage")))
(check-true
 (asset-ok (check-release-assets (manifest appimage) gh-base (table "App.AppImage" (facts)))))
;; unknown installer kind skips the extension check but keeps the other gates.
(define unknown-kind (list (artifact #:installer 'custom #:name "App.bin")))
(check-true
 (asset-ok (check-release-assets (manifest unknown-kind) gh-base (table "App.bin" (facts)))))
;; unsafe signed filename.
(define unsafe (list (artifact #:name "../escape.msi")))
(check-false (hash-ref (check-release-assets (manifest unsafe) gh-base (hasheq)) 'ok))

;; ---- check-release-assets: duplicates and required targets ---------------

(define dup
  (list (artifact #:platform 'windows #:installer 'msi #:name "App.msi")
        (artifact #:platform 'windows #:installer 'zip #:name "App.msi")))
(check-false (hash-ref (check-release-assets (manifest dup) gh-base (table "App.msi" (facts))) 'ok))

(define multi
  (list (artifact #:platform 'windows #:installer 'msi #:name "App.msi")
        (artifact #:platform 'linux #:installer 'appimage #:name "App.AppImage")))
(define multi-facts (table "App.msi" (facts) "App.AppImage" (facts)))
(check-true (hash-ref (check-release-assets (manifest multi)
                                            gh-base
                                            multi-facts
                                            #:required-targets
                                            '((windows x64 msi) (linux x64 appimage)))
                      'ok))
(define missing-target
  (check-release-assets (manifest multi) gh-base multi-facts #:required-targets '((macos arm64 dmg))))
(check-false (hash-ref missing-target 'ok))
(check-equal? (hash-ref missing-target 'required-targets-missing) '("macos:arm64:dmg"))

;; ---- end-to-end CLI shell (OpenSSL-gated) --------------------------------

;; The shell authenticates a real signed manifest and reads real file facts
;; from a release directory. Signing needs the OpenSSL 3 CLI; environments
;; without it (package-build sandboxes, LibreSSL-only macOS) skip this leg
;; instead of failing, exactly like the update signing tests.
(when (openssl-available?)
  (define work (make-temporary-directory "glaze-release-assets-~a"))
  (dynamic-wind void
                (lambda ()
                  (define release-dir (build-path work "release"))
                  (make-directory* release-dir)
                  (define private-key (build-path work "private.pem"))
                  (define public-key (build-path work "public.pem"))
                  (signing-keygen #:private-key private-key #:public-key public-key)
                  (define asset-path (build-path release-dir "App-1.2.0.msi"))
                  (define payload #"glaze release asset payload")
                  (call-with-output-file asset-path
                                         (lambda (out) (write-bytes payload out))
                                         #:exists 'truncate/replace
                                         #:mode 'binary)
                  (define signed-artifact
                    (update-artifact 'windows
                                     'x64
                                     (string-append gh-base "/App-1.2.0.msi")
                                     (sha256-file asset-path)
                                     (file-size asset-path)
                                     'msi
                                     '()
                                     #f))
                  (define signed-manifest
                    (update-manifest "com.example.app"
                                     "1.2.0"
                                     1
                                     'stable
                                     "2026-01-01T00:00:00Z"
                                     "1.0.0"
                                     #f
                                     #t
                                     100
                                     (list signed-artifact)))
                  (define manifest-path (build-path work "manifest.json"))
                  (call-with-output-file
                   manifest-path
                   (lambda (out)
                     (write-signed-update-manifest signed-manifest private-key "release-2026" out))
                   #:exists 'truncate/replace)
                  (define (invoke . extra)
                    (parameterize ([current-output-port (open-output-nowhere)])
                      (verify-release-assets-command (append (list (path->string manifest-path)
                                                                   (path->string release-dir)
                                                                   (path->string public-key)
                                                                   "--base-url"
                                                                   gh-base
                                                                   "--key-id"
                                                                   "release-2026")
                                                             extra))))
                  (check-equal? (invoke "--json") 0)
                  (check-equal? (invoke "--require" "windows:x64:msi") 0)
                  (check-equal? (invoke "--require" "macos:arm64:dmg") 1)
                  (call-with-output-file asset-path
                                         (lambda (out) (write-bytes #"tampered" out))
                                         #:exists 'truncate/replace
                                         #:mode 'binary)
                  (check-equal? (invoke) 1))
                (lambda () (delete-directory/files work))))

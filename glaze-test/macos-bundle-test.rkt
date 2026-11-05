#lang racket/base

;; Direct contract for macOS bundle staging. assemble-macos-bundle is pure
;; file work, so every platform exercises the real transformation; the
;; PlistBuddy post-process leg runs only where that tool exists.

(require racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         rackunit
         glaze/private/macos-bundle)

(define work-root (make-temporary-file "glaze-macos-bundle-test-~a" 'directory))

;; ---- assemble a canonical bundle from a flat raco distribute output ----

(define dist (build-path work-root "assemble-dist"))
(make-directory* (build-path dist "bin"))
(make-directory* (build-path dist "lib"))
(call-with-output-file (build-path dist "bin" "BundleApp")
                       (lambda (out) (display "payload" out))
                       #:exists 'replace)
(unless (eq? (system-type 'os) 'windows)
  (file-or-directory-permissions (build-path dist "bin" "BundleApp") #o755))
(call-with-output-file (build-path dist "lib" "data.txt")
                       (lambda (out) (display "lib-payload" out))
                       #:exists 'replace)

(assemble-macos-bundle dist "BundleApp" "1.2.3" '("myscheme"))

(define contents (build-path dist "BundleApp.app" "Contents"))
(check-true (file-exists? (build-path contents "MacOS" "BundleApp")) "executable moved into MacOS")
(check-equal? (file->string (build-path contents "MacOS" "BundleApp")) "payload")
(check-true
 (> (arithmetic-shift (file-or-directory-permissions (build-path contents "MacOS" "BundleApp") 'bits)
                      -6)
    0)
 "the launcher stays executable")
(check-true (directory-exists? (build-path contents "lib")) "library tree moved into Contents")
(check-equal? (file->string (build-path contents "lib" "data.txt")) "lib-payload")
(check-false (directory-exists? (build-path dist "bin")) "the flat bin/ layout is consumed")
(check-equal? (file->string (build-path contents "PkgInfo")) "APPL????")

(define plist (file->string (build-path contents "Info.plist")))
(check-true (string-contains? plist "CFBundleName</key><string>BundleApp"))
(check-true (string-contains? plist "CFBundleExecutable</key><string>BundleApp"))
(check-true (string-contains? plist "CFBundleShortVersionString</key><string>1.2.3"))
(check-true (string-contains? plist "CFBundleVersion</key><string>1.2.3"))
(check-true (string-contains? plist "io.glaze.BundleApp"))
(check-true (string-contains? plist "myscheme") "declared URL schemes land in CFBundleURLTypes")

;; ---- assembly fails loudly without a launcher ----

(define empty-dist (build-path work-root "empty-dist"))
(make-directory* (build-path empty-dist "bin"))
(check-exn #rx"macOS bundle assembly failed"
           (lambda () (assemble-macos-bundle empty-dist "Missing" "0.0.0")))

;; ---- post-process patches the plist where PlistBuddy exists ----

(when (find-executable-path "PlistBuddy" #f)
  (define icon (build-path work-root "BundleApp.icns"))
  (call-with-output-file icon (lambda (out) (write-bytes #"icns-bytes" out)) #:exists 'replace)
  (post-process-macos-bundle dist "BundleApp" icon "3.4.5")
  (define patched (file->string (build-path contents "Info.plist")))
  (check-true (string-contains? patched "CFBundleShortVersionString</key><string>3.4.5")
              "the configured version overrides the assembled one")
  (check-true (string-contains? patched "CFBundleIdentifier</key><string>io.glaze.BundleApp"))
  (check-true (file-exists? (build-path contents "Resources" "BundleApp.icns"))
              "the icon is copied into Resources")
  (check-true (string-contains? patched "CFBundleIconFile</key><string>BundleApp.icns")
              "the plist references the bundled icon"))

;; Rebuilding into the same dist replaces the bundle instead of failing on
;; the existing destination (the second `raco glaze build` regression).
(make-directory* (build-path dist "bin"))
(call-with-output-file (build-path dist "bin" "BundleApp")
                       (lambda (out) (display "second payload" out))
                       #:exists 'replace)
(assemble-macos-bundle dist "BundleApp" "1.2.4" '())
(check-equal? (file->string (build-path contents "MacOS" "BundleApp")) "second payload")
(check-false (directory-exists? (build-path contents "lib"))
             "a rebuild does not keep the previous bundle's library tree")

;; ---- dmg staging always carries the /Applications drop target ----

(unless (eq? (system-type 'os) 'windows)
  (define dmg-stage (build-path work-root "dmg-stage"))
  (make-directory* dmg-stage)
  (stage-dmg-root (build-path dist "BundleApp.app") dmg-stage "BundleApp")
  (check-true (file-exists? (build-path dmg-stage "BundleApp.app" "Contents" "Info.plist"))
              "the staged dmg contains the bundle")
  (check-equal? (string-trim (with-output-to-string
                              (lambda ()
                                (system* (find-executable-path "readlink" #f)
                                         (path->string (build-path dmg-stage "Applications"))))))
                "/Applications"
                "the dmg offers the conventional Applications drop target"))

(delete-directory/files work-root)

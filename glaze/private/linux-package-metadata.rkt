#lang racket/base

;; Deterministic Linux package metadata and the generated fallback icon. The
;; actual toolchain invocation/staging is owned by glaze/private/linux-package.

(require racket/list
         racket/path
         racket/string
         "png.rkt")

(provide deb-arch-name
         rpm-arch-name
         sanitize-package-name
         sanitize-package-version
         desktop-entry
         deb-control
         rpm-spec
         icon-png-bytes
         png-dimensions)

;; ---- shared Linux package metadata ----

;; deb Architecture / rpm BuildArch names.
(define (deb-arch-name)
  (case (system-type 'arch)
    [(x86_64 amd64) "amd64"]
    [(aarch64 arm64) "arm64"]
    [else "all"]))

(define (rpm-arch-name)
  (case (system-type 'arch)
    [(x86_64 amd64) "x86_64"]
    [(aarch64 arm64) "aarch64"]
    [else "noarch"]))

;; deb Package names are lowercase [a-z0-9+-.].
(define (sanitize-package-name app-name)
  (define lowered (string-downcase app-name))
  (define cleaned
    (regexp-replace* #rx"-*$"
                     (regexp-replace* #rx"^-*"
                                      (apply string-append
                                             (for/list ([c (in-string lowered)])
                                               (if (or (char<=? #\a c #\z)
                                                       (char<=? #\0 c #\9)
                                                       (memq c '(#\. #\+ #\-)))
                                                   (string c)
                                                   "-")))
                                      "")
                     ""))
  (if (non-empty-string? cleaned) cleaned "app"))

;; rpm Version fields reject dashes.
;; Debian and rpm compare a prerelease after the release when it is written
;; "1.0.0.beta" (that is newer than 1.0.0); "~" is the ordering marker that
;; places it before. Map the SemVer prerelease separator to "~" and replace
;; any other punctuation, so installing stable over a beta is an upgrade.
(define (sanitize-package-version version)
  (define seen-prerelease? #f)
  (define cleaned
    (apply string-append
           (for/list ([c (in-string version)])
             (cond
               [(or (char-alphabetic? c) (char-numeric? c)) (string c)]
               [(memq c '(#\. #\+)) (string c)]
               [(char=? c #\-)
                (if seen-prerelease?
                    "."
                    (begin
                      (set! seen-prerelease? #t)
                      "~"))]
               [else "."]))))
  (if (non-empty-string? cleaned) cleaned "0.0.0"))

;; The icon name is the hicolor/AppDir icon stem; appimagetool refuses a
;; desktop file without a resolvable Icon entry.
(define (desktop-entry app-name [icon-name #f])
  (format
   "[Desktop Entry]\nType=Application\nName=~a\nExec=~a~a\nTerminal=false\nCategories=Utility;\n"
   app-name
   app-name
   (if icon-name
       (format "\nIcon=~a" icon-name)
       "")))

(define (deb-control app-name version publisher arch)
  (format
   "Package: ~a\nVersion: ~a\nArchitecture: ~a\nMaintainer: ~a\nSection: utils\nPriority: optional\nDescription: ~a desktop application (built with Glaze)\n"
   (sanitize-package-name app-name)
   (sanitize-package-version version)
   arch
   (if (non-empty-string? publisher) publisher "Unknown maintainer")
   app-name))

(define (rpm-spec app-name version publisher staging-root [icon-bucket "64x64"])
  (format #<<SPECEOF
Name: ~a
Version: ~a
Release: 1
Summary: ~a desktop application (built with Glaze)
License: Unknown
BuildArch: ~a
%description
~a desktop application packaged by Glaze; publisher: ~a.
%prep
%build
%install
mkdir -p %{buildroot}
cp -a ~a/usr %{buildroot}/
%files
/usr/bin/~a
/usr/lib/~a
/usr/share/applications/~a.desktop
/usr/share/icons/hicolor/~a/apps/~a.png
SPECEOF
          (sanitize-package-name app-name)
          (sanitize-package-version version)
          app-name
          (rpm-arch-name)
          app-name
          (if (non-empty-string? publisher) publisher "unknown")
          (path->string staging-root)
          app-name
          app-name
          app-name
          icon-bucket
          (sanitize-package-name app-name)))

;; ---- generated placeholder icon ----

;; A flat-color square PNG in pure Racket (zlib stored blocks + adler32):
;; projects without an icon still get a valid hicolor/AppDir icon instead
;; of a broken desktop integration or a failing appimagetool run.
;; Read width/height from a PNG's IHDR chunk. Returns two values, or #f #f
;; when the bytes are not a PNG — callers fall back to the placeholder icon
;; bucket instead of guessing a size.
(define (png-dimensions bs)
  (if (and (>= (bytes-length bs) 24)
           (equal? (subbytes bs 0 8) #"\211PNG\r\n\032\n")
           (equal? (subbytes bs 12 16) #"IHDR"))
      (values (integer-bytes->integer (subbytes bs 16 20) #f #t)
              (integer-bytes->integer (subbytes bs 20 24) #f #t))
      (values #f #f)))

(define (icon-png-bytes [size 64] [r #xC1] [g #x5F] [b #x3C])
  (define row (apply bytes (append-map (lambda (_) (list r g b)) (range size))))
  (rgb-png-bytes size size (apply bytes-append (make-list size row))))

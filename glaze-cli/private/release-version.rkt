#lang racket/base

;; `raco glaze check-release-version [<tag>] [--info FILE] [--carrier FILE]...
;;  [--allow-rc] [--json]` — preflight the release version metadata before a
;; tag is cut. Reads the two info.rkt version bindings through setup/getinfo,
;; requires CHANGELOG.md to carry the release, verifies an optional tag against
;; the release version (release candidates need --allow-rc), and checks every
;; declared carrier file. Exit 0 only when everything aligns; any problem fails
;; closed so an inconsistent release cannot be tagged. See docs/RELEASING.md.

(require json
         racket/file
         racket/format
         racket/list
         racket/path
         racket/string
         setup/getinfo
         glaze/private/release-version)

(provide release-version-command)

(define (release-version-command rest)
  (define-values (tag options) (parse-release-version-arguments rest))
  (define info-file (hash-ref options 'info "info.rkt"))
  (define info-path
    (if (absolute-path? info-file)
        (string->path info-file)
        (build-path (current-directory) info-file)))
  (define root (simplify-path (or (path-only info-path) (current-directory))))
  (define gi
    (with-handlers ([exn:fail? (lambda (_) #f)])
      (get-info/full root)))
  (define version (and gi (gi 'version (lambda () #f))))
  (define release-version (and gi (gi 'release-version (lambda () #f))))
  (define changelog-path (build-path root "CHANGELOG.md"))
  (define changelog
    (and (file-exists? changelog-path)
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (file->string changelog-path))))
  (define carriers
    (for/list ([declared (in-list (reverse (hash-ref options 'carriers '())))])
      (define path
        (if (absolute-path? declared)
            (string->path declared)
            (build-path root declared)))
      (cons (path->string path)
            (and (file-exists? path)
                 (with-handlers ([exn:fail? (lambda (_) #f)])
                   (file->string path))))))
  (define report
    (check-release-version #:version version
                           #:release-version release-version
                           #:tag tag
                           #:allow-rc? (hash-ref options 'allow-rc? #f)
                           #:changelog changelog
                           #:carriers carriers))
  (cond
    [(hash-ref options 'json? #f)
     (write-json report (current-output-port))
     (newline (current-output-port))]
    [else
     (printf "release preflight: version ~a / release-version ~a\n"
             (or version "(missing)")
             (or release-version "(missing)"))
     (for ([problem (in-list (hash-ref report 'problems))])
       (printf "  - ~a\n" problem))
     (if (hash-ref report 'ok)
         (displayln "OK: release version metadata is aligned")
         (displayln "FAIL: resolve the version problems above before tagging"))])
  (if (hash-ref report 'ok) 0 1))
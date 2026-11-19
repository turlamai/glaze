#lang racket/base

;; CLI shell for the offline release-asset gate. It authenticates the signed
;; update manifest through glaze/update (Ed25519 over the payload bytes, with an
;; optional key-id pin), gathers the real file facts from the release directory,
;; and delegates every alignment rule to the pure core. No network access,
;; update installation, or private signing key is involved. The command exits 0
;; only when every gate passes; any divergence — including a manifest that fails
;; authentication — fails closed with exit 1.

(require json
         racket/list
         glaze/update
         glaze/signing
         glaze/private/release-assets)

(provide verify-release-assets-command)

(define (verify-release-assets-command rest)
  (define-values (manifest-path release-dir public-key-path options)
    (parse-verify-release-assets-arguments rest))
  (define json? (hash-ref options 'json? #f))
  (define (fail! message)
    (cond
      [json?
       (write-json (hasheq 'ok #f 'problems (list message)))
       (newline)]
      [else (printf "release asset verification FAILED: ~a\n" message)])
    1)
  (with-handlers ([exn:fail? (lambda (e) (fail! (exn-message e)))])
    ;; Authenticate the bytes before trusting any payload field.
    (define manifest
      (call-with-input-file
       manifest-path
       (lambda (in)
         (verify-signed-update-manifest in public-key-path #:key-id (hash-ref options 'key-id #f)))))
    (define base-url (hash-ref options 'base-url))
    (define asset-facts
      (for/hash ([artifact (in-list (update-manifest-artifacts manifest))])
        (define name (asset-name-for-url (update-artifact-url artifact) base-url))
        (if name
            (let ([path (build-path release-dir name)])
              (define symlink? (link-exists? path))
              (define exists? (file-exists? path))
              (define regular? (and exists? (not symlink?)))
              (values name
                      (hasheq 'exists?
                              exists?
                              'symlink?
                              symlink?
                              'size
                              (and regular? (file-size path))
                              'sha256
                              (and regular? (sha256-file path)))))
            (values (update-artifact-url artifact)
                    (hasheq 'exists? #f 'symlink? #f 'size #f 'sha256 #f)))))
    (define report
      (check-release-assets manifest
                            base-url
                            asset-facts
                            #:application-id (hash-ref options 'application-id #f)
                            #:required-targets (hash-ref options 'required-targets '())))
    (cond
      [json?
       (write-json report)
       (newline)]
      [(hash-ref report 'ok)
       (printf "verified ~a signed release assets for ~a ~a\n"
               (length (hash-ref report 'assets))
               (hash-ref report 'application-id)
               (hash-ref report 'version))]
      [else
       (printf "release asset verification FAILED for ~a ~a:\n"
               (hash-ref report 'application-id)
               (hash-ref report 'version))
       (for ([problem (in-list (hash-ref report 'problems))])
         (printf "  - ~a\n" problem))])
    (if (hash-ref report 'ok) 0 1)))

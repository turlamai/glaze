#lang racket/base

;; End-to-end portable update flow: a signed manifest selects N+1, the
;; artifact digest is checked, the directory install replaces N, and a
;; failed restart restores it. Network transport stays out of this test
;; (HTTPS is covered by the downloader's own contract); the manifest and
;; artifact checks are the security boundary exercised here.

(require racket/file
         racket/port
         racket/system
         rackunit
         glaze/signing
         glaze/update)

(define work (make-temporary-file "glaze-update-flow-~a" 'directory))
(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace (lambda (out) (display text out))))
(define (read-version dir)
  (file->string (build-path dir "Contents" "version.txt")))

(define v1 (build-path work "v1"))
(define v2 (build-path work "v2"))
(write-text (build-path v1 "Contents" "version.txt") "1.0.0")
(write-text (build-path v2 "Contents" "version.txt") "2.0.0")

(define archive (build-path work "v2.tar.gz"))
(define tar (find-executable-path "tar" #f))
(check-not-false tar "this test needs tar to package the update")
(define (run-tar . args)
  (unless (apply system* tar args)
    (error 'update-install-flow "tar failed: ~a" args)))
(run-tar "-czf" (path->string archive) "-C" (path->string v2) ".")

(define public-key (build-path work "public.pem"))
(define private-key (build-path work "private.pem"))
(define artifact
  (update-artifact 'windows
                   'x64
                   "https://updates.example/app.tar.gz"
                   (sha256-file archive)
                   (file-size archive)
                   'tar.gz
                   '()
                   #f))
(define manifest
  (update-manifest "dev.glaze.test"
                   "2.0.0"
                   20
                   'stable
                   "2026-11-05T00:00:00Z"
                   "1.0.0"
                   "1.0.0"
                   #t
                   100
                   (list artifact)))
(define config
  (updater-config "dev.glaze.test"
                  "1.0.0"
                  'stable
                  'windows
                  'x64
                  public-key
                  "release-2026"
                  0
                  (* 1024 1024)))

(define candidate (select-update config manifest))
(check-true (update-candidate? candidate) "N+1 is selected for N")
(check-equal? (verify-update-artifact! candidate archive)
              archive
              "the artifact matches the signed digest and size")

;; A same-size corruption must fail on the digest, not slip through.
(define corrupt (build-path work "corrupt.tar.gz"))
(define bytes (file->bytes archive))
(bytes-set! bytes 0 (bitwise-xor 255 (bytes-ref bytes 0)))
(call-with-output-file corrupt (lambda (out) (write-bytes bytes out)) #:exists 'truncate/replace)
(check-exn #rx"download SHA-256 does not match"
           (lambda () (verify-update-artifact! candidate corrupt)))

;; Extract the verified artifact and replace the installed directory.
(define extract (build-path work "extract"))
(make-directory* extract)
(run-tar "-xzf" (path->string archive) "-C" (path->string extract))
(execute-install-plan! (make-replace-install-plan candidate extract v1))
(check-equal? (read-version v1) "2.0.0" "the installed tree is N+1")
(check-equal? (read-version (build-path work "v1.rollback"))
              "1.0.0"
              "the previous tree is kept for rollback")

;; A restart failure restores N instead of leaving a half-applied update.
(define failed-target (build-path work "failed"))
(make-directory* (build-path failed-target "Contents"))
(write-text (build-path failed-target "Contents" "version.txt") "1.0.0")
(check-exn #rx"restart failed"
           (lambda ()
             (execute-install-plan! (make-replace-install-plan
                                     candidate
                                     extract
                                     failed-target
                                     #:restart (lambda () (error 'restart "restart failed"))))))
(check-equal? (read-version failed-target) "1.0.0" "a failed restart restores the previous version")

;; Manifest signature and key-id pinning, when this host can sign.
(when (openssl-available?)
  (signing-keygen #:private-key private-key #:public-key public-key)
  (define signed (open-output-bytes))
  (write-signed-update-manifest manifest private-key "release-2026" signed)
  (define verified
    (verify-signed-update-manifest (open-input-bytes (get-output-bytes signed))
                                   public-key
                                   #:key-id "release-2026"))
  (check-equal? (update-manifest-version verified) "2.0.0")
  (check-true (update-candidate? (select-update config verified)))
  (check-exn #rx"unexpected key"
             (lambda ()
               (verify-signed-update-manifest (open-input-bytes (get-output-bytes signed))
                                              public-key
                                              #:key-id "other-key"))))

(delete-directory/files work)

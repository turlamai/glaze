#lang racket/base

;; Live HTTPS update download: a local CA and TLS server serve a signed
;; manifest and artifact; the client selects, verifies, downloads and applies
;; N+1. Skips when this host cannot sign Ed25519 (macOS LibreSSL) or lacks
;; openssl.

(require racket/file
         racket/path
         racket/port
         racket/string
         racket/system
         racket/tcp
         rackunit
         glaze/signing
         glaze/update)

(define work (make-temporary-file "glaze-https-update-~a" 'directory))
(define (write-text path text)
  (make-parent-directory* path)
  (call-with-output-file path #:exists 'truncate/replace (lambda (out) (display text out))))
(define (run! path . args)
  (unless (apply system* path args)
    (error 'update-download-flow "command failed: ~a ~a" path args)))
(define (cleanup!)
  (when (directory-exists? work)
    (delete-directory/files work)))

(define (main)
  (define openssl (and (openssl-available?) (find-executable-path "openssl" #f)))
  (unless openssl
    (displayln "HTTPS update flow skipped: OpenSSL 3 is unavailable")
    (cleanup!)
    (exit 0))
  (define ca-key (build-path work "ca.key"))
  (define ca-pem (build-path work "ca.pem"))
  (define server-key (build-path work "server.key"))
  (define server-csr (build-path work "server.csr"))
  (define server-pem (build-path work "server.pem"))
  (define ext (build-path work "san.cnf"))
  (write-text ext "subjectAltName=DNS:localhost,IP:127.0.0.1\n")
  (run! openssl
        "req"
        "-x509"
        "-newkey"
        "rsa:2048"
        "-nodes"
        "-keyout"
        (path->string ca-key)
        "-out"
        (path->string ca-pem)
        "-subj"
        "/CN=Glaze Test CA"
        "-days"
        "1")
  (run! openssl
        "req"
        "-newkey"
        "rsa:2048"
        "-nodes"
        "-keyout"
        (path->string server-key)
        "-out"
        (path->string server-csr)
        "-subj"
        "/CN=localhost")
  (run! openssl
        "x509"
        "-req"
        "-in"
        (path->string server-csr)
        "-CA"
        (path->string ca-pem)
        "-CAkey"
        (path->string ca-key)
        "-CAcreateserial"
        "-out"
        (path->string server-pem)
        "-days"
        "1"
        "-extfile"
        (path->string ext))

  (define v1 (build-path work "v1"))
  (define v2 (build-path work "v2"))
  (write-text (build-path v1 "Contents" "version.txt") "1.0.0")
  (write-text (build-path v2 "Contents" "version.txt") "2.0.0")
  (define archive (build-path work "app.tar.gz"))
  (parameterize ([current-directory work])
    (run! (find-executable-path "tar" #f) "-czf" "app.tar.gz" "-C" "v2" "."))

  ;; One dedicated test port; CI runs a single instance.
  (define port 28443)

  (define private-key (build-path work "private.pem"))
  (define public-key (build-path work "public.pem"))
  (signing-keygen #:private-key private-key #:public-key public-key)

  (define artifact
    (update-artifact 'windows
                     'x64
                     (format "https://localhost:~a/app.tar.gz" port)
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
  (call-with-output-file (build-path work "manifest.json")
                         (lambda (out)
                           (write-signed-update-manifest manifest private-key "release-2026" out))
                         #:exists 'truncate/replace)

  ;; Trust only the test CA for this process.
  (putenv "SSL_CERT_FILE" (path->string ca-pem))
  (putenv "SSL_CERT_DIR" (path->string work))

  (define-values (proc proc-in proc-out proc-err)
    (parameterize ([current-directory work])
      (subprocess #f
                  #f
                  #f
                  openssl
                  "s_server"
                  "-quiet"
                  "-WWW"
                  "-accept"
                  (number->string port)
                  "-cert"
                  (path->string server-pem)
                  "-key"
                  (path->string server-key))))
  (dynamic-wind
   void
   (lambda ()
     (let loop ([tries 50])
       (unless (with-handlers ([exn:fail? (lambda (_) #f)])
                 (define-values (in out) (tcp-connect "127.0.0.1" port))
                 (close-input-port in)
                 (close-output-port out)
                 #t)
         (when (zero? tries)
           (subprocess-kill proc #t)
           (error 'update-download-flow "TLS server did not start"))
         (sleep 0.1)
         (loop (sub1 tries))))

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
     (define fetched
       (fetch-update-manifest (format "https://localhost:~a/manifest.json" port)
                              public-key
                              #:key-id "release-2026"))
     (define candidate (select-update config fetched))
     (check-true (update-candidate? candidate) "the HTTPS manifest selects N+1")

     (define downloaded (build-path work "downloaded.tar.gz"))
     (check-equal? (download-update config candidate downloaded) downloaded)
     (check-equal? (file-size downloaded) (file-size archive))

     ;; Corrupting the served bytes must fail the digest check.
     (define bytes (file->bytes archive))
     (bytes-set! bytes 10 (bitwise-xor 255 (bytes-ref bytes 10)))
     (call-with-output-file archive (lambda (out) (write-bytes bytes out)) #:exists 'truncate/replace)
     (check-exn #rx"download SHA-256 does not match"
                (lambda () (download-update config candidate (build-path work "bad.tar.gz"))))

     ;; Install the verified copy (download-update verified it).
     (define extract (build-path work "extract"))
     (make-directory* extract)
     (parameterize ([current-directory work])
       (run! (find-executable-path "tar" #f) "-xzf" "downloaded.tar.gz" "-C" "extract"))
     (execute-install-plan! (make-replace-install-plan candidate extract v1))
     (check-equal? (file->string (build-path v1 "Contents" "version.txt")) "2.0.0"))
   (lambda ()
     (with-handlers ([exn:fail? void])
       (subprocess-kill proc #t)
       (subprocess-wait proc)))))

(dynamic-wind void main cleanup!)

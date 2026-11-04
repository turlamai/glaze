#lang racket/base

;; Read the public half of an update key without the OpenSSL CLI. Glaze's
;; updater historically required a system `openssl` 3 to verify a manifest,
;; which meant end users needed a developer toolchain to install updates.
;; Verification only needs a public key, so parse the standard Ed25519
;; SubjectPublicKeyInfo form directly: 44-byte DER or the PEM wrapper that
;; `raco glaze updater-keygen` writes.

(require net/base64
         racket/bytes
         racket/file
         racket/string)

(provide read-public-key-components
         public-key-der
         der->public-key)

(define spki-prefix #"\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00")
(define spki-length 44)

(define (public-key-der public)
  (unless (and (bytes? public) (= 32 (bytes-length public)))
    (raise-argument-error 'public-key-der "32-byte public key" public))
  (bytes-append spki-prefix public))

(define (der->public-key der)
  (unless (and (bytes? der)
               (= spki-length (bytes-length der))
               (bytes=? (subbytes der 0 12) spki-prefix))
    (raise-arguments-error 'der->public-key
                           "public key is not a 44-byte Ed25519 SubjectPublicKeyInfo"
                           "bytes"
                           (if (bytes? der)
                               (bytes-length der)
                               der)))
  (subbytes der 12 spki-length))

(define (pem-body text)
  (define lines
    (for/list ([line (in-list (string-split text "\n"))]
               #:unless (or (string=? (string-trim line) "")
                            (string-prefix? (string-trim line) "-----")))
      (string-trim line)))
  (base64-decode (string->bytes/utf-8 (string-join lines ""))))

;; Returns (values public-key-bytes spki-der-bytes). Accepts the PEM that
;; updater-keygen writes and the raw 44-byte DER form.
(define (read-public-key-components path)
  (define raw (file->bytes path))
  (define der
    (cond
      [(and (= (bytes-length raw) spki-length) (bytes=? (subbytes raw 0 12) spki-prefix)) raw]
      [else
       (define text (bytes->string/utf-8 raw))
       (unless (string-contains? text "BEGIN PUBLIC KEY")
         (error 'verify-bytes "public key is neither PEM SubjectPublicKeyInfo nor 44-byte DER"))
       (define decoded
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (pem-body text)))
       (unless (and decoded
                    (= (bytes-length decoded) spki-length)
                    (bytes=? (subbytes decoded 0 12) spki-prefix))
         (error 'verify-bytes "public key PEM does not contain an Ed25519 SubjectPublicKeyInfo"))
       decoded]))
  (values (subbytes der 12 spki-length) der))

#lang racket/base

;; Pure PNG encoder shared by Linux capture and package icons. Stored
;; deflate blocks avoid foreign image encoders and nested GLib callbacks.
(provide rgb-png-bytes)

(define crc32-table
    (for/vector #:length 256
                ([n (in-naturals)])
      (for/fold ([c n]) ([_ (in-range 8)])
        (if (zero? (bitwise-and c 1))
            (arithmetic-shift c -1)
            (bitwise-xor #xEDB88320 (arithmetic-shift c -1))))))

(define (crc32-bytes data)
  (bitwise-xor #xFFFFFFFF
               (for/fold ([c #xFFFFFFFF]) ([b (in-bytes data)])
                 (bitwise-and #xFFFFFFFF (vector-ref crc32-table (bitwise-xor (bitwise-and c #xFF) b))))))

(define (adler32-bytes data)
  ;; RFC 1950: s1/s2 accumulate modulo 65521, not a 16-bit mask — masking
  ;; instead of reducing silently corrupts the checksum for larger payloads.
  (define mod 65521)
  (let loop ([i 0]
             [a 1]
             [b 0])
    (if (= i (bytes-length data))
        (+ (* (modulo b mod) 65536) (modulo a mod))
        (let ([a2 (modulo (+ a (bytes-ref data i)) mod)]) (loop (add1 i) a2 (modulo (+ b a2) mod))))))

;; zlib stream using stored (uncompressed) deflate blocks.
(define (zlib-store-bytes data)
  (define out (open-output-bytes))
  (write-bytes (bytes #x78 #x01) out)
  (let loop ([offset 0])
    (define len (min 65535 (- (bytes-length data) offset)))
    (define next (+ offset len))
    (define final? (= next (bytes-length data)))
    (define nlen (bitwise-xor len #xFFFF))
    (write-bytes (bytes (if final? 1 0)
                        (bitwise-and len #xFF)
                        (arithmetic-shift len -8)
                        (bitwise-and nlen #xFF)
                        (arithmetic-shift nlen -8))
                 out)
    (write-bytes data out offset next)
    (unless final? (loop next)))
  (write-bytes (integer->integer-bytes (adler32-bytes data) 4 #f #t) out)
  (get-output-bytes out))

(define (png-chunk type data)
  (define type-bytes (string->bytes/latin-1 type))
  (define body (bytes-append type-bytes data))
  (bytes-append (integer->integer-bytes (bytes-length data) 4 #f #t)
                body
                (integer->integer-bytes (crc32-bytes body) 4 #f #t)))


(define (rgb-png-bytes width height pixels #:stride [stride (* width 3)] #:channels [channels 3])
  (unless (and (exact-positive-integer? width)
               (exact-positive-integer? height)
               (memv channels '(3 4))
               (exact-integer? stride)
               (>= stride (* width channels))
               (bytes? pixels)
               (>= (bytes-length pixels) (+ (* (sub1 height) stride) (* width channels))))
    (raise-arguments-error 'rgb-png-bytes "invalid pixel buffer or geometry"
                           "width" width "height" height "stride" stride "channels" channels))
  (define row-size (add1 (* width channels)))
  (define raw (make-bytes (* height row-size) 0))
  (for ([y (in-range height)])
    (define source (* y stride))
    (bytes-copy! raw (add1 (* y row-size)) pixels source (+ source (* width channels))))
  (bytes-append #"\211PNG\r\n\032\n"
                (png-chunk "IHDR"
                           (bytes-append (integer->integer-bytes width 4 #f #t)
                                         (integer->integer-bytes height 4 #f #t)
                                         (bytes 8 (if (= channels 4) 6 2) 0 0 0)))
                (png-chunk "IDAT" (zlib-store-bytes raw))
                (png-chunk "IEND" #"")))

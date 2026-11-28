#lang racket/base

(require rackunit
         file/gunzip
         glaze/private/png)

(define (decode png)
  (define n (integer-bytes->integer png #f #t 33 37))
  (check-equal? (subbytes png 37 41) #"IDAT")
  (define z (subbytes png 41 (+ 41 n)))
  (define out (open-output-bytes))
  (inflate (open-input-bytes (subbytes z 2 (- (bytes-length z) 4))) out)
  (get-output-bytes out))

(test-case "RGB row padding is excluded"
  (define png (rgb-png-bytes 1 2 (bytes 1 2 3 99 4 5 6) #:stride 4))
  (check-equal? (decode png) (bytes 0 1 2 3 0 4 5 6)))

(test-case "RGBA format preserves alpha"
  (define png (rgb-png-bytes 1 1 (bytes 1 2 3 4) #:stride 4 #:channels 4))
  (check-equal? (bytes-ref png 25) 6)
  (check-equal? (decode png) (bytes 0 1 2 3 4)))

(test-case "large screenshots interleave multiple deflate blocks correctly"
  (define pixels (make-bytes (* 400 300 3) 127))
  (define png (rgb-png-bytes 400 300 pixels))
  (define raw (decode png))
  (check-equal? (bytes-length raw) (* 300 1201))
  (for ([y (in-range 300)])
    (check-equal? (bytes-ref raw (* y 1201)) 0)
    (check-equal? (subbytes raw (add1 (* y 1201)) (* (add1 y) 1201)) (make-bytes 1200 127))))

(test-case "truncated buffers fail before encoding"
  (check-exn exn:fail:contract? (lambda () (rgb-png-bytes 2 2 (make-bytes 11)))))

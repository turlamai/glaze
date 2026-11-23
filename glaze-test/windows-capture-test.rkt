#lang racket/base
;; Direct tests for glaze/private/windows-capture's pure BMP encoder.
;;
;; glaze#140: GetDIBits returns TOP-DOWN rows while a BMP with a positive
;; biHeight stores the BOTTOM scanline first. Writing the buffer as-is
;; mirrored every Windows `webview-capture!`. The encoder runs on every
;; platform (the native half resolves lazily), so CI guards the orientation
;; rule on all three operating systems.

(require rackunit
         racket/list
         "../glaze/private/windows-capture.rkt")

(define (read-le bs off size)
  (define acc 0)
  (for ([i (in-range size)])
    (set! acc (+ acc (arithmetic-shift (bytes-ref bs (+ off i)) (* 8 i)))))
  acc)

(define (bgra r g b)
  (bytes b g r 255))

;; Scanlines of a BMP file in top-to-bottom display order.
(define (bmp-top-down-rows bmp width height)
  (define row-bytes (* 4 width))
  (for/list ([y (in-range height)])
    (subbytes bmp (+ 54 (* (- height y 1) row-bytes)) (+ 54 (* (- height y) row-bytes)))))

(define-check (check-header bmp width height)
  (define image-size (* 4 width height))
  (check-equal? (subbytes bmp 0 2) #"BM" "file signature")
  (check-equal? (read-le bmp 2 4) (+ 54 image-size) "file size")
  (check-equal? (read-le bmp 10 4) 54 "pixel offset")
  (check-equal? (read-le bmp 14 4) 40 "BITMAPINFOHEADER size")
  (check-equal? (read-le bmp 18 4) width "width")
  (check-equal? (read-le bmp 22 4) height "height is positive: bottom-up storage")
  (check-equal? (read-le bmp 26 2) 1 "planes")
  (check-equal? (read-le bmp 28 2) 32 "bits per pixel")
  (check-equal? (read-le bmp 30 4) 0 "BI_RGB")
  (check-equal? (read-le bmp 34 4) image-size "image size")
  (check-equal? (bytes-length bmp) (+ 54 image-size) "total length"))

(test-case "a 2x2 image stores the bottom scanline first"
  (define pixels
    (bytes-append (bgra 255 0 0)
                  (bgra 0 255 0) ; top row: red, green
                  (bgra 0 0 255)
                  (bgra 9 9 9))) ; bottom row: blue, gray
  (define bmp (top-down-bgra->bmp-bytes 2 2 pixels))
  (check-header bmp 2 2)
  (define rows (bmp-top-down-rows bmp 2 2))
  (check-equal? (first rows) (bytes-append (bgra 255 0 0) (bgra 0 255 0)) "top row stays on top")
  (check-equal? (second rows)
                (bytes-append (bgra 0 0 255) (bgra 9 9 9))
                "bottom row stays at the bottom"))

(test-case "a 1x4 image is not vertically mirrored (glaze#140)"
  (define rows-src (list (bgra 255 0 0) (bgra 0 255 0) (bgra 0 0 255) (bgra 0 0 0)))
  (define bmp (top-down-bgra->bmp-bytes 1 4 (apply bytes-append rows-src)))
  (check-header bmp 1 4)
  (check-equal? (bmp-top-down-rows bmp 1 4) rows-src "file rows decode back in buffer order")
  ;; The first stored scanline is the LAST buffer row.
  (check-equal? (subbytes bmp 54 58) (bgra 0 0 0) "bottom-up file starts with the bottom row"))

(test-case "widths that are not multiples of four still have 4-byte aligned rows"
  (define w 3)
  (define pixels (make-bytes (* 4 w 2) 7))
  (define bmp (top-down-bgra->bmp-bytes w 2 pixels))
  (check-header bmp w 2)
  (check-equal? (subbytes bmp 54 58) (bytes 7 7 7 7)))

(test-case "invalid arguments are rejected before any encoding"
  (check-exn exn:fail:contract? (lambda () (top-down-bgra->bmp-bytes 0 1 (bytes 0 0 0 0))))
  (check-exn exn:fail:contract? (lambda () (top-down-bgra->bmp-bytes 1 -1 (bytes 0 0 0 0))))
  (check-exn exn:fail:contract? (lambda () (top-down-bgra->bmp-bytes 2 2 (bytes 0 0 0 0))))
  (check-exn exn:fail:contract? (lambda () (top-down-bgra->bmp-bytes 1 1 "not bytes"))))

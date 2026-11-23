#lang racket/base
;; Windows window capture: PrintWindow into a DIB, encode a BMP, and convert
;; it to PNG with Windows PowerShell's System.Drawing (present on every
;; Windows install). Owned here, outside the WebView2 backend, so the backend
;; keeps only the WebView lifecycle and the row-order conversion is pure and
;; testable on every platform (glaze-test/windows-capture-test.rkt).
;;
;; Orientation contract (glaze#140): GetDIBits is asked for a TOP-DOWN DIB
;; (negative biHeight), where buffer row 0 is the top of the window. A BMP
;; file with a positive biHeight stores the BOTTOM scanline first. Writing
;; the buffer as-is therefore mirrored every capture; the encoder below
;; stores the rows in reverse so the file matches what the user sees.

(require ffi/unsafe
         racket/file
         racket/string
         racket/path

         racket/system)

(provide top-down-bgra->bmp-bytes
         capture-window->png)

;; ---- pure: top-down 32-bit BGRA pixels -> BMP file bytes ----

(define bmp-file-header-size 14)
(define bmp-info-header-size 40)
(define bmp-pixel-offset (+ bmp-file-header-size bmp-info-header-size))

;; `pixels` holds width*height 4-byte BGRA records, top row first. 32-bit
;; rows are always DWORD-aligned, so the file needs no scanline padding.
(define (top-down-bgra->bmp-bytes width height pixels)
  (unless (exact-positive-integer? width)
    (raise-argument-error 'top-down-bgra->bmp-bytes "exact-positive-integer?" width))
  (unless (exact-positive-integer? height)
    (raise-argument-error 'top-down-bgra->bmp-bytes "exact-positive-integer?" height))
  (unless (and (bytes? pixels) (= (bytes-length pixels) (* 4 width height)))
    (raise-argument-error 'top-down-bgra->bmp-bytes
                          (format "bytes of length ~a" (* 4 width height))
                          pixels))
  (define row-bytes (* 4 width))
  (define image-size (* row-bytes height))
  (define file-size (+ bmp-pixel-offset image-size))
  (define out (make-bytes file-size 0))
  ;; BITMAPFILEHEADER
  (bytes-copy! out 0 #"BM")
  (integer->integer-bytes file-size 4 #f #f out 2)
  (integer->integer-bytes bmp-pixel-offset 4 #f #f out 10)
  ;; BITMAPINFOHEADER: positive height = bottom-up storage.
  (integer->integer-bytes bmp-info-header-size 4 #f #f out 14)
  (integer->integer-bytes width 4 #f #f out 18)
  (integer->integer-bytes height 4 #f #f out 22)
  (integer->integer-bytes 1 2 #f #f out 26) ; planes
  (integer->integer-bytes 32 2 #f #f out 28) ; bits per pixel
  (integer->integer-bytes image-size 4 #f #f out 34)
  ;; Pixel data: file row y is buffer row (height - 1 - y).
  (for ([y (in-range height)])
    (define buffer-top (* (- height y 1) row-bytes))
    (bytes-copy! out (+ bmp-pixel-offset (* y row-bytes)) pixels buffer-top (+ buffer-top row-bytes)))
  out)

;; ---- native: window -> PNG path ----

;; Resolve a value (shared library) on first use.
(define-syntax-rule (define-lazy-value id expr)
  (begin
    (define cached (box #f))
    (define (id)
      (or (unbox cached)
          (let ([v expr])
            (set-box! cached v)
            v)))))

;; Resolves an FFI function on first call, so the pure encoder above can be
;; required and tested on any platform while the native half stays lazy.
(define-syntax-rule (define-lazy-binding id expr)
  (begin
    (define-lazy-value id-procedure expr)
    (define (id . args)
      (apply (id-procedure) args))))

(define-lazy-value user32 (ffi-lib "user32"))
(define-lazy-value gdi32 (ffi-lib "gdi32"))

(define-cstruct _RECT ([left _long] [top _long] [right _long] [bottom _long]))
;; BITMAPINFOHEADER + BITMAPINFO for GetDIBits.
(define-cstruct _BMIH
                ([biSize _uint] [biWidth _long]
                                [biHeight _long]
                                [biPlanes _ushort]
                                [biBitCount _ushort]
                                [biCompression _uint]
                                [biSizeImage _uint]
                                [biXPelsPerMeter _long]
                                [biYPelsPerMeter _long]
                                [biClrUsed _uint]
                                [biClrImportant _uint]))
(define-cstruct _BMI ([bmiHeader _BMIH] [bmiColors _uint32]))

(define-lazy-binding
 GetClientRect
 (get-ffi-obj "GetClientRect" (user32) (_fun _pointer _pointer -> _bool) (lambda () #f)))
(define-lazy-binding GetDC (get-ffi-obj "GetDC" (user32) (_fun _pointer -> _pointer)))
(define-lazy-binding ReleaseDC (get-ffi-obj "ReleaseDC" (user32) (_fun _pointer _pointer -> _int)))
(define-lazy-binding CreateCompatibleDC
                     (get-ffi-obj "CreateCompatibleDC" (gdi32) (_fun _pointer -> _pointer)))
(define-lazy-binding
 CreateCompatibleBitmap
 (get-ffi-obj "CreateCompatibleBitmap" (gdi32) (_fun _pointer _int _int -> _pointer)))
(define-lazy-binding SelectObject
                     (get-ffi-obj "SelectObject" (gdi32) (_fun _pointer _pointer -> _pointer)))
(define-lazy-binding DeleteObject (get-ffi-obj "DeleteObject" (gdi32) (_fun _pointer -> _bool)))
(define-lazy-binding DeleteDC (get-ffi-obj "DeleteDC" (gdi32) (_fun _pointer -> _bool)))
(define-lazy-binding PrintWindow
                     (get-ffi-obj "PrintWindow" (user32) (_fun _pointer _pointer _uint -> _bool)))
(define-lazy-binding
 GetDIBits
 (get-ffi-obj "GetDIBits"
              (gdi32)
              (_fun _pointer _pointer _uint _uint _pointer _pointer _uint -> _int)))

(define PW_RENDERFULLCONTENT 2)
(define BI_RGB 0)
(define DIB_RGB_COLORS 0)

(define (capture-failure stage detail)
  (raise (exn:fail (format "capture: ~a ~a" stage detail) (current-continuation-marks))))

;; Print the window's client area into a fresh top-down 32-bit buffer.
;; Returns (list width height pixels) or #f for an empty client area.
(define (print-window-pixels hwnd)
  (define rc (make-RECT 0 0 0 0))
  (unless (GetClientRect hwnd rc)
    (capture-failure "GetClientRect failed for" hwnd))
  (define w (- (RECT-right rc) (RECT-left rc)))
  (define h (- (RECT-bottom rc) (RECT-top rc)))
  (and (> w 0)
       (> h 0)
       (let ()
         (define hdc (GetDC hwnd))
         (define mem (CreateCompatibleDC hdc))
         (define bmp (CreateCompatibleBitmap hdc w h))
         (define raw (malloc (* 4 w h) _uint8 'raw))
         (define pixels (make-bytes (* 4 w h)))
         (dynamic-wind
          void
          (lambda ()
            (define old (SelectObject mem bmp))
            (dynamic-wind void
                          (lambda ()
                            (unless (PrintWindow hwnd mem PW_RENDERFULLCONTENT)
                              (capture-failure "PrintWindow failed for" hwnd))
                            (define bmi
                              (make-BMI (make-BMIH (ctype-sizeof _BMIH)
                                                   w
                                                   (- h) ; top-down: buffer row 0 is the window top
                                                   1
                                                   32
                                                   BI_RGB
                                                   0 ; biSizeImage
                                                   0 ; biXPelsPerMeter
                                                   0 ; biYPelsPerMeter
                                                   0 ; biClrUsed
                                                   0) ; biClrImportant
                                        0))
                            (define got (GetDIBits mem bmp 0 h raw bmi DIB_RGB_COLORS))
                            (unless (= got h)
                              (capture-failure "GetDIBits copied" (format "~a of ~a rows" got h)))
                            (memcpy pixels raw (* 4 w h)))
                          (lambda () (SelectObject mem old))))
          (lambda ()
            (DeleteObject bmp)
            (DeleteDC mem)
            (ReleaseDC hwnd hdc)))
         (list w h pixels))))

;; Single-quoted PowerShell string literal.
(define (ps-literal s)
  (string-append "'" (string-replace s "'" "''") "'"))

(define (bmp-bytes->png bmp png-path)
  (define bmp-path (make-temporary-file "glaze-capture-~a.bmp"))
  (define ps-exe (find-executable-path "powershell.exe"))
  (dynamic-wind
   void
   (lambda ()
     (call-with-output-file bmp-path (lambda (o) (write-bytes bmp o)) #:exists 'replace)
     (and ps-exe
          (system* ps-exe
                   "-NoProfile"
                   "-NonInteractive"
                   "-Command"
                   (string-append "Add-Type -AssemblyName System.Drawing;"
                                  "$b=[System.Drawing.Bitmap]::FromFile("
                                  (ps-literal (path->string bmp-path))
                                  ");$b.Save("
                                  (ps-literal (path->string png-path))
                                  ", [System.Drawing.Imaging.ImageFormat]::Png);$b.Dispose()"))
          (file-exists? png-path)
          png-path))
   (lambda () (delete-file bmp-path))))

;; Capture hwnd's client area as a PNG. `dest` is a path-like string, a path,
;; or #f for a fresh temporary file. Returns the PNG path, or #f when the
;; client area is empty or the PNG conversion failed.
(define (capture-window->png hwnd dest)
  (define pixels (print-window-pixels hwnd))
  (and pixels
       (let ([w (list-ref pixels 0)]
             [h (list-ref pixels 1)]
             [buffer (list-ref pixels 2)])
         (define png-path
           (if dest
               (if (string? dest)
                   (string->path dest)
                   dest)
               (make-temporary-file "glaze-capture-~a.png")))
         (bmp-bytes->png (top-down-bgra->bmp-bytes w h buffer) png-path))))

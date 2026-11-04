#lang racket/base

;; The WebView2 loader is architecture-specific: a native arm64 Racket
;; process cannot load the x64 DLL (and vice versa). Keep the mapping in one
;; place so the runtime backend and the packaging path cannot disagree.

(provide webview2-loader-subdir)

(define (webview2-loader-subdir [arch (system-type 'arch)])
  (case arch
    [(x86_64) "win-x64"]
    [(aarch64) "win-arm64"]
    [else (error 'webview2-loader "no WebView2Loader.dll for Racket architecture ~a" arch)]))

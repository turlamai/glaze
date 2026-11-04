#lang racket/base

(require rackunit
         glaze/private/win32-arch)

(check-equal? (webview2-loader-subdir 'x86_64) "win-x64")
(check-equal? (webview2-loader-subdir 'aarch64) "win-arm64")
(check-exn exn:fail?
           (lambda () (webview2-loader-subdir 'x86))
           "32-bit Windows is not a supported target")

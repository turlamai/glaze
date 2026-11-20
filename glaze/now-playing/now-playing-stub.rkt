#lang racket/base

;; Inert Now Playing backend (Windows today: the WebView2 SMTC MediaSession
;; bridge is the verified OS surface; host SMTC may follow later). Also the
;; dispatcher's fallback when a native backend cannot load.

(provide supported? publish! os-info set-handler!)

(define (supported?) #f)
(define (publish! info handler) (void))
(define (os-info) #f)
(define (set-handler! proc) (void))
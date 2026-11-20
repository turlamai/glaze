#lang racket/base

;; Contract for the launch-smoke pure core borrowed from rivet: session
;; classification, bounded-capture arithmetic, and truncation rendering.
;; No subprocesses here — the effectful drain/early-exit behavior is
;; exercised against staged executables in measure-test.rkt.

(require rackunit
         glaze/private/launch-smoke)

;; ---- session-name-interactive? ------------------------------------------

;; Interactive Windows shells commonly omit SESSIONNAME entirely.
(check-true (session-name-interactive? ""))
(check-true (session-name-interactive? "Console"))
(check-true (session-name-interactive? "RDP-Tcp#0"))
;; The Services session cannot host a GUI app, in any casing.
(check-false (session-name-interactive? "Services"))
(check-false (session-name-interactive? "services"))
(check-false (session-name-interactive? "Service-0x0-3e7$"))
(check-false (session-name-interactive? #f))

;; ---- capture-keep-length -------------------------------------------------

(check-equal? maximum-captured-output-bytes 65536)
;; A fresh capture keeps the whole chunk.
(check-equal? (capture-keep-length 0 4096) 4096)
;; A chunk straddling the bound keeps only the remainder.
(check-equal? (capture-keep-length 65000 4096) 536)
;; Exactly at the bound keeps the full chunk.
(check-equal? (capture-keep-length 61440 4096) 4096)
;; Past the bound nothing is kept, but the caller keeps draining.
(check-equal? (capture-keep-length 65536 4096) 0)
(check-equal? (capture-keep-length 70000 4096) 0)
(check-equal? (capture-keep-length 0 0) 0)

;; ---- captured-output-text ------------------------------------------------

(check-equal? (captured-output-text #"hello" #f) "hello")
(check-equal? (captured-output-text #"" #f) "")
;; Invalid UTF-8 renders as the replacement character, never an exception.
(check-equal? (captured-output-text #"ok\xffbad" #f) "ok\uFFFDbad")
;; Truncation is announced with the exact bound.
(check-equal? (captured-output-text #"tail" #t) "[output truncated at 65536 bytes]\ntail")

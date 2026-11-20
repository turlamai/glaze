#lang racket/base

;; Pure core for the launch-smoke hardening borrowed from rivet's
;; launch-smoke contract: bounded output capture and session classification
;; with no ports, threads, or environment access, so the arithmetic and
;; formatting are testable on every platform without spawning anything.

(require racket/string)

(provide maximum-captured-output-bytes
         session-name-interactive?
         capture-keep-length
         captured-output-text)

;; Capture at most 64 KiB per stream, but keep draining past the bound so a
;; noisy child cannot fill its pipe, block, and appear healthy only because
;; it is stuck.
(define maximum-captured-output-bytes (* 64 1024))

;; Windows SESSIONNAME classification: interactive shells commonly omit the
;; variable entirely (empty string), while the Services session is the one
;; known non-interactive value and cannot host a GUI app.
(define (session-name-interactive? name)
  (and (string? name) (not (string-prefix? (string-downcase name) "service"))))

;; How many bytes of a chunk still fit under the capture bound.
(define (capture-keep-length captured chunk-length)
  (max 0 (min (- maximum-captured-output-bytes captured) chunk-length)))

;; Render captured bytes for a failure report: invalid UTF-8 becomes the
;; replacement character, and truncation is announced rather than silent.
(define (captured-output-text raw truncated?)
  (define text (bytes->string/utf-8 raw #\uFFFD))
  (if truncated?
      (string-append "[output truncated at "
                     (number->string maximum-captured-output-bytes)
                     " bytes]\n"
                     text)
      text))
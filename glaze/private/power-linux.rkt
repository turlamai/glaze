#lang racket/base

;; systemd-inhibit holds the logind inhibitor FD for the lifetime of its
;; child. A readiness line is emitted only after the inhibitor is acquired.
;; No user-controlled string is interpolated into shell source.
(require racket/system
         racket/port)

(provide supported? acquire!)

(define (supported?)
  (and (find-executable-path "systemd-inhibit")
       (find-executable-path "sh")
       #t))

(define (acquire! kind reason)
  ;; logind's idle inhibitor is not a display-specific assertion.
  ;; Refuse display requests rather than claiming equivalent protection.
  (and (eq? kind 'system)
       (supported?)
       (let-values ([(proc out in err)
                     (subprocess #f #f #f
                                 (find-executable-path "systemd-inhibit")
                                 "--what=sleep" "--mode=block"
                                 "--who=Glaze" (string-append "--why=" reason)
                                 (find-executable-path "sh") "-c"
                                 "printf 'ready\\n'; cat >/dev/null")])
         (define (release!)
           (unless (port-closed? in) (close-output-port in))
           (unless (sync/timeout 3 proc)
             (subprocess-kill proc #t)
             (sync/timeout 3 proc))
           (unless (port-closed? out) (close-input-port out))
           (unless (port-closed? err) (close-input-port err))
           (not (eq? (subprocess-status proc) 'running)))
         (define ready (sync/timeout 5 (read-line-evt out 'any)))
         (if (and (equal? ready "ready")
                  (eq? (subprocess-status proc) 'running))
             release!
             (begin (release!) #f)))))

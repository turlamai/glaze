#lang racket/base

;; `raco glaze acceptance` — run the headless acceptance gates that are
;; meaningful on any platform (doctor usability + the compliance license
;; audit) and emit one bounded, self-describing envelope report. The
;; per-platform reports are folded by `raco glaze matrix`. Mirrors rivet's
;; `acceptance --json`; the doctor report is injected by the dispatcher so
;; this private module never imports an aggregate command module.

(require json
         racket/format
         racket/string
         glaze/private/acceptance
         glaze/private/compliance)

(provide acceptance-command
         parse-acceptance-opts)

(define (parse-acceptance-opts args)
  (let loop ([args args]
             [opts (hasheq 'json #f 'out #f)])
    (cond
      [(null? args) opts]
      [(member (car args) '("--json" "-j")) (loop (cdr args) (hash-set opts 'json #t))]
      [(equal? (car args) "--out")
       (when (null? (cdr args))
         (error 'acceptance "--out requires a file"))
       (loop (cddr args) (hash-set opts 'out (cadr args)))]
      [(string-prefix? (car args) "--out=")
       (loop (cdr args) (hash-set opts 'out (substring (car args) 6)))]
      [else (error 'acceptance "unknown option: ~a" (car args))])))

(define (write-json-file path report)
  (call-with-output-file path (lambda (out) (write-json report out)) #:exists 'truncate))

(define (acceptance-command rest #:doctor doctor-thunk)
  (define opts (parse-acceptance-opts rest))
  (define doctor-report
    (with-handlers ([exn:fail? (lambda (e) (hasheq 'usable #f 'problems (list (exn-message e))))])
      (doctor-thunk)))
  (define doctor-ok (and (hash? doctor-report) (hash-ref doctor-report 'usable #f) #t))
  (define closure (dependency-closure '("glaze") package-metadata))
  (define audit (audit-report closure))
  (define compliance-ok (hash-ref audit 'ok))
  (define checks
    (hasheq 'doctor
            (hasheq 'ok
                    doctor-ok
                    'problems
                    (if (hash? doctor-report)
                        (hash-ref doctor-report 'problems '())
                        '()))
            'compliance
            (hasheq 'ok
                    compliance-ok
                    'components
                    (length (hash-ref audit 'components))
                    'problems
                    (hash-ref audit 'problems))))
  (define ok (and doctor-ok compliance-ok))
  (define report (acceptance-envelope "acceptance" (current-platform) ok checks))
  (define out (hash-ref opts 'out))
  (when out
    (write-json-file out report))
  (cond
    [(hash-ref opts 'json)
     (write-json report)
     (newline)]
    [else
     (printf "Glaze acceptance (~a): ~a~n" (current-platform) (if ok "ok" "FAILED"))
     (printf "  doctor: ~a~n" (if doctor-ok "ok" "failed"))
     (printf "  compliance: ~a (~a components)~n"
             (if compliance-ok "ok" "failed")
             (length (hash-ref audit 'components)))
     (when out
       (printf "  wrote ~a~n" out))])
  (if ok 0 1))

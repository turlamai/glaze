#lang racket/base

;; Measurement for packaged apps (G4-S2, the pattern learned from Rivet's
;; `raco rivet measure`): one command that reports what a packaged app
;; actually weighs and whether it still fits its budgets, so release CI can
;; gate sizes mechanically instead of eyeballing dist listings. Size is
;; fully deterministic here; startup wraps a launch-survival window around
;; the packaged artifact. Per-request latency stays with the framework
;; baseline harness (scripts/measure-baseline.rkt, docs/benchmarks.md),
;; which measures the real transport end to end.

(require file/glob
         json
         racket/file
         racket/format
         racket/list
         racket/match
         racket/path
         racket/string
         racket/system)

(provide measure-command
         measure-size
         measure-startup
         display-size-report
         display-startup-report
         launch-survival!
         parse-budget-file
         dist-artifacts
         (struct-out exn:fail:glaze:budget))

(define dist-directory "dist")

;; Budget violations raise this so callers can distinguish "measured fine"
;; from "over budget" without parsing output.
(struct exn:fail:glaze:budget exn:fail () #:transparent)

;; A macOS .app is a directory but still one shippable artifact. Generic
;; directories (raco distribute's bin/ and lib/) are layout, not artifacts.
(define (app-bundle? path)
  (and (directory-exists? path) (string-suffix? (path->string (file-name-from-path path)) ".app")))

(define (dist-artifacts root)
  (define dist (build-path root dist-directory))
  (if (directory-exists? dist)
      (sort (for/list ([path (in-list (directory-list dist #:build? #t))]
                       #:when (or (file-exists? path) (app-bundle? path)))
              path)
            #:key path->string
            string<?)
      '()))

(define (artifact-size path)
  (if (directory-exists? path)
      (for/fold ([total 0]) ([child (in-directory path)])
        (if (file-exists? child)
            (+ total (file-size child))
            total))
      (file-size path)))

(define (format-bytes count)
  (define mb (/ count 1024.0 1024.0))
  (if (>= mb 1.0)
      (format "~a (~a MiB)" count (~r mb #:precision 1))
      (format "~a bytes" count)))

;; Budget files are JSON: {"rules": [{"glob": "*.dmg", "max-bytes":
;; 100000000}, ...]}. The first matching rule wins, so list the most
;; specific glob first.
(define (parse-budget-file path)
  (unless (file-exists? path)
    (error 'measure "budget file ~a does not exist" path))
  (define document
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (error 'measure "budget file ~a is not valid JSON: ~a" path (exn-message e)))])
      (call-with-input-file path read-json)))
  (define rules (hash-ref document 'rules (lambda () #f)))
  (unless (and (list? rules)
               (for/and ([rule (in-list rules)])
                 (and (hash? rule)
                      (string? (hash-ref rule 'glob (lambda () #f)))
                      (exact-positive-integer? (hash-ref rule 'max-bytes (lambda () #f))))))
    (error 'measure
           "budget file ~a must contain {\"rules\": [{\"glob\": ..., \"max-bytes\": ...}, ...]}"
           path))
  rules)

(define (budget-for rules artifact)
  (define name (path->string (file-name-from-path artifact)))
  (for/first ([rule (in-list rules)]
              #:when (glob-match? (hash-ref rule 'glob) name))
    (hash-ref rule 'max-bytes)))

(define (matching-artifacts artifacts artifact-filter)
  (if artifact-filter
      (filter (lambda (path) (equal? (path->string (file-name-from-path path)) artifact-filter))
              artifacts)
      artifacts))

(define (select-artifacts root artifact-filter who)
  (define artifacts (matching-artifacts (dist-artifacts root) artifact-filter))
  (when (null? artifacts)
    (error who
           "no packaged artifacts under ~a; run `raco glaze build` first"
           (build-path root dist-directory)))
  artifacts)

(define (measure-size project-root #:budget-path [budget-path #f] #:artifact [artifact-filter #f])
  (define artifacts (select-artifacts project-root artifact-filter 'measure-size))
  (define rules (and budget-path (parse-budget-file budget-path)))
  (define violations '())
  (define rows
    (for/list ([artifact (in-list artifacts)])
      (define bytes (artifact-size artifact))
      (define budget (and rules (budget-for rules artifact)))
      (when (and budget (> bytes budget))
        (set! violations (cons (cons artifact (cons bytes budget)) violations)))
      (hash 'name (path->string (file-name-from-path artifact)) 'bytes bytes 'budget-bytes budget)))
  (hash 'artifacts (reverse rows) 'violations (reverse violations)))

(define (display-size-report report)
  (for ([row (in-list (hash-ref report 'artifacts))])
    (define budget (hash-ref row 'budget-bytes))
    (printf "  ~a: ~a~a\n"
            (hash-ref row 'name)
            (format-bytes (hash-ref row 'bytes))
            (if budget
                (format " [budget ~a]" (format-bytes budget))
                "")))
  (for ([violation (in-list (hash-ref report 'violations))])
    (printf "  OVER BUDGET: ~a is ~a against a ~a budget\n"
            (path->string (file-name-from-path (car violation)))
            (format-bytes (car (cdr violation)))
            (format-bytes (cdr (cdr violation))))))

;; Launch-survival window: spawn the packaged artifact, require it to still
;; be alive after `seconds`, then terminate it. Reports the elapsed window
;; so a packaged app's ability to boot on this machine is measured rather
;; than assumed. A bundle (.app on macOS) is unwrapped to its inner binary.
(define (launch-survival! artifact seconds)
  (define target
    (if (and (directory-exists? artifact)
             (string-suffix? (path->string (file-name-from-path artifact)) ".app"))
        (build-path artifact
                    "Contents"
                    "MacOS"
                    (path-replace-extension (file-name-from-path artifact) #""))
        artifact))
  (unless (file-exists? target)
    (error 'measure "no executable artifact at ~a" target))
  (define started (current-inexact-milliseconds))
  ;; subprocess returns (process stdout stdin stderr): the process first.
  (define-values (p _stdout _stdin _stderr)
    (with-handlers ([exn:fail? (lambda (e)
                                 (error 'measure "could not launch ~a: ~a" target (exn-message e)))])
      (subprocess #f #f #f target)))
  (sleep seconds)
  ;; subprocess-status is the SYMBOL 'running while alive, the exit code
  ;; once it terminates — same shape rivet's launch smoke checks.
  (define alive (eq? (subprocess-status p) 'running))
  (when alive
    ;; Kill the whole tree on Windows. A staged launcher (a .bat/.cmd or an
    ;; installer stub) can leave descendants that keep the staged directory
    ;; locked; terminating only the direct process makes later cleanup and
    ;; repeat builds fail with "permission denied".
    (if (eq? (system-type 'os) 'windows)
        (let ([pid (subprocess-pid p)])
          (unless (zero? (system*/exit-code "taskkill" "/PID" (number->string pid) "/T" "/F"))
            (subprocess-kill p #t)))
        (subprocess-kill p #t)))
  (subprocess-wait p)
  (unless alive
    (error 'measure
           "packaged artifact ~a exited before its ~a second survival window ended"
           (file-name-from-path target)
           seconds))
  (/ (- (current-inexact-milliseconds) started) 1000.0))

;; Startup can also launch a distribution that keeps its executable under
;; dist/bin/ (the Linux/Windows `raco distribute` layout).
(define (startup-candidates root)
  (define dist (build-path root dist-directory))
  (define bin (build-path dist "bin"))
  (define bin-files
    (if (directory-exists? bin)
        (filter file-exists? (directory-list bin #:build? #t))
        '()))
  (append (dist-artifacts root) bin-files))

(define (measure-startup project-root #:artifact [artifact-filter #f] #:seconds [seconds 3.0])
  (define artifacts (matching-artifacts (startup-candidates project-root) artifact-filter))
  (when (null? artifacts)
    (error 'measure-startup
           "no packaged artifacts under ~a; run `raco glaze build` first"
           (build-path project-root dist-directory)))
  ;; dist and bin/ keep manifests/sidecars too, so smoke the largest non-data
  ;; file (or .app bundle).
  (define launchable
    (filter (lambda (path)
              (not (regexp-match? #rx"[.](json|txt|sha256|sig|zip|tar[.]gz|msi|deb|rpm)$"
                                  (path->string path))))
            artifacts))
  (when (null? launchable)
    (error 'measure-startup
           "no executable artifact under ~a"
           (build-path project-root dist-directory)))
  (define artifact (argmax artifact-size launchable))
  (define elapsed (launch-survival! artifact seconds))
  (hash 'artifact
        (path->string (file-name-from-path artifact))
        'survival-seconds
        elapsed
        'required-seconds
        seconds))

(define (display-startup-report report)
  (printf "  ~a survived its ~a second launch window (~a elapsed)\n"
          (hash-ref report 'artifact)
          (hash-ref report 'required-seconds)
          (~r (hash-ref report 'survival-seconds) #:precision 2)))

(define (require-option-value who option args)
  (unless (pair? (cdr args))
    (error who "~a requires a value" option))
  (cadr args))

(define (check-size-budget report)
  (unless (null? (hash-ref report 'violations))
    (raise (exn:fail:glaze:budget "size budgets exceeded; see the OVER BUDGET lines above"
                                  (current-continuation-marks)))))

(define (run-size root args)
  (let loop ([args args]
             [budget #f]
             [artifact #f])
    (cond
      [(null? args)
       (define report (measure-size root #:budget-path budget #:artifact artifact))
       (display-size-report report)
       (check-size-budget report)]
      [(equal? (car args) "--budget")
       (loop (cddr args) (require-option-value 'measure "--budget" args) artifact)]
      [(equal? (car args) "--artifact")
       (loop (cddr args) budget (require-option-value 'measure "--artifact" args))]
      [else (error 'measure "unknown size option ~a" (car args))])))

(define (run-startup root args)
  (let loop ([args args]
             [artifact #f]
             [seconds #f])
    (cond
      [(null? args)
       (define report
         (if seconds
             (measure-startup root #:artifact artifact #:seconds seconds)
             (measure-startup root #:artifact artifact)))
       (display-startup-report report)]
      [(equal? (car args) "--artifact")
       (loop (cddr args) (require-option-value 'measure "--artifact" args) seconds)]
      [(equal? (car args) "--seconds")
       (define raw (require-option-value 'measure "--seconds" args))
       (define n
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (string->number raw)))
       (unless (and (real? n) (positive? n))
         (error 'measure "--seconds requires a positive number"))
       (loop (cddr args) artifact n)]
      [else (error 'measure "unknown startup option ~a" (car args))])))

(define (measure-command rest)
  (define root (current-directory))
  (match rest
    [(list "size" args ...) (run-size root args)]
    [(list "startup" args ...) (run-startup root args)]
    [_
     (error
      'measure
      "unknown measurement ~a; use `size [--budget <file>] [--artifact <name>]` or `startup [--artifact <name>] [--seconds N]`"
      (string-join (if (null? rest)
                       '("(none)")
                       rest)
                   " "))]))

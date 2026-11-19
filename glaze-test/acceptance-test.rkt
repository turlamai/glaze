#lang racket/base

;; Acceptance envelope + cross-platform matrix aggregation (rivet
;; acceptance/matrix parity). The pure core is exercised without I/O; the
;; two commands are exercised end-to-end against temporary report files,
;; and acceptance runs its real headless gates when glaze is installed.

(require rackunit
         json
         racket/file
         racket/string
         glaze/private/acceptance
         glaze/private/compliance
         glaze-cli/private/acceptance
         glaze-cli/private/matrix)

(define (rep gate platform ok)
  (acceptance-envelope gate platform ok (hasheq)))

(define (with-temp-dir proc)
  (define dir (make-temporary-file "glaze-acceptance-~a" 'directory))
  (dynamic-wind void (lambda () (proc dir)) (lambda () (delete-directory/files dir))))

(define (write-report dir name r)
  (define p (build-path dir name))
  (call-with-output-file p (lambda (o) (write-json r o)) #:exists 'truncate)
  p)

(define (quiet thunk)
  (parameterize ([current-output-port (open-output-string)])
    (thunk)))

;; --- envelope ----------------------------------------------------------

(test-case "envelope carries the shared identity"
  (define r (rep "acceptance" "linux" #t))
  (check-equal? (hash-ref r 'contract-version) 1)
  (check-equal? (hash-ref r 'product) "Glaze")
  (check-equal? (hash-ref r 'gate) "acceptance")
  (check-equal? (hash-ref r 'platform) "linux")
  (check-true (hash-ref r 'ok)))

(test-case "current-platform is a non-empty string"
  (check-true (and (string? (current-platform)) (> (string-length (current-platform)) 0))))

;; --- validation (fail closed) ------------------------------------------

(test-case "well-formed envelope validates"
  (check-false (leg-error (rep "g" "p" #t))))

(test-case "non-object is rejected"
  (check-true (string? (leg-error 42))))

(test-case "missing contract-version is rejected"
  (check-true (string? (leg-error (hasheq 'product "Glaze" 'gate "g" 'platform "p" 'ok #t)))))

(test-case "foreign product is rejected"
  (check-true (string? (leg-error (hash-set (rep "g" "p" #t) 'product "Other")))))

(test-case "empty gate is rejected"
  (check-true (string? (leg-error (rep "" "p" #t)))))

(test-case "non-boolean ok is rejected"
  (check-true (string? (leg-error (hash-set (rep "g" "p" #t) 'ok "yes")))))

;; --- aggregation -------------------------------------------------------

(test-case "all-ok matrix rolls up true and sorts legs"
  (define m (aggregate-matrix (list (rep "acceptance" "windows" #t) (rep "acceptance" "linux" #t))))
  (check-true (hash-ref m 'ok))
  (check-equal? (hash-ref m 'platforms) '("linux" "windows"))
  (check-equal? (hash-ref m 'gates) '("acceptance"))
  (check-equal? (map (lambda (l) (hash-ref l 'platform)) (hash-ref m 'legs)) '("linux" "windows")))

(test-case "a failed leg fails the matrix"
  (check-false (hash-ref (aggregate-matrix (list (rep "a" "linux" #t) (rep "a" "macosx" #f))) 'ok)))

(test-case "empty matrix fails closed (no evidence is not a pass)"
  (check-false (hash-ref (aggregate-matrix '()) 'ok)))

(test-case "malformed report becomes a problem"
  (define m (aggregate-matrix (list (rep "a" "linux" #t) (hasheq 'bogus #t))))
  (check-false (hash-ref m 'ok))
  (check-equal? (length (hash-ref m 'problems)) 1))

(test-case "agreeing duplicate legs are deduplicated"
  (define m (aggregate-matrix (list (rep "a" "linux" #t) (rep "a" "linux" #t))))
  (check-true (hash-ref m 'ok))
  (check-equal? (length (hash-ref m 'legs)) 1))

(test-case "conflicting duplicate legs are flagged"
  (define m (aggregate-matrix (list (rep "a" "linux" #t) (rep "a" "linux" #f))))
  (check-false (hash-ref m 'ok))
  (check-true (for/or ([p (in-list (hash-ref m 'problems))])
                (string-contains? p "conflicting"))))

(test-case "legs stay bounded to platform/gate/ok"
  (define m
    (aggregate-matrix
     (list (acceptance-envelope "a" "linux" #t (hasheq 'big (make-string 1000 #\x))))))
  (for ([l (in-list (hash-ref m 'legs))])
    (check-equal? (sort (hash-keys l) symbol<?) '(gate ok platform))))

(test-case "matrix folds multiple gates across platforms"
  (define m
    (aggregate-matrix (list (rep "acceptance" "linux" #t)
                            (rep "coldsmoke" "linux" #t)
                            (rep "acceptance" "windows" #t))))
  (check-true (hash-ref m 'ok))
  (check-equal? (hash-ref m 'gates) '("acceptance" "coldsmoke"))
  (check-equal? (length (hash-ref m 'legs)) 3))

;; --- option parsing ----------------------------------------------------

(test-case "matrix opts collect files and flags"
  (define o (parse-matrix-opts '("a.json" "--json" "b.json" "--out" "m.json")))
  (check-equal? (hash-ref o 'files) '("a.json" "b.json"))
  (check-true (hash-ref o 'json))
  (check-equal? (hash-ref o 'out) "m.json"))

(test-case "acceptance opts parse"
  (define o (parse-acceptance-opts '("--json" "--out" "a.json")))
  (check-true (hash-ref o 'json))
  (check-equal? (hash-ref o 'out) "a.json"))

;; --- matrix command end-to-end -----------------------------------------

(test-case "matrix-command folds files and writes the matrix"
  (with-temp-dir (lambda (dir)
                   (define a (write-report dir "a.json" (rep "acceptance" "linux" #t)))
                   (define b (write-report dir "b.json" (rep "acceptance" "windows" #t)))
                   (define out (build-path dir "m.json"))
                   (define code
                     (quiet (lambda ()
                              (matrix-command
                               (list (path->string a) (path->string b) "--out" (path->string out))))))
                   (check-equal? code 0)
                   (define m (call-with-input-file out read-json))
                   (check-true (hash-ref m 'ok))
                   (check-equal? (hash-ref m 'platforms) '("linux" "windows")))))

(test-case "matrix-command fails closed on a failed leg"
  (with-temp-dir (lambda (dir)
                   (define a (write-report dir "a.json" (rep "acceptance" "linux" #f)))
                   (check-equal? (quiet (lambda () (matrix-command (list (path->string a))))) 1))))

(test-case "matrix-command reports unreadable files as problems"
  (with-temp-dir
   (lambda (dir)
     (define missing (build-path dir "nope.json"))
     (define out (build-path dir "m.json"))
     (define code
       (quiet (lambda () (matrix-command (list (path->string missing) "--out" (path->string out))))))
     (check-equal? code 1)
     (define m (call-with-input-file out read-json))
     (check-false (hash-ref m 'ok))
     (check-true (pair? (hash-ref m 'problems))))))

;; --- acceptance command (real headless gates when installed) -----------

(test-case "acceptance-command emits a bounded envelope and fails closed"
  (define md (package-metadata "glaze"))
  (when (not (hash-ref md 'missing #f))
    (with-temp-dir
     (lambda (dir)
       (define out (build-path dir "a.json"))
       (define code
         (quiet (lambda ()
                  (acceptance-command (list "--json" "--out" (path->string out))
                                      #:doctor (lambda () (hasheq 'usable #t 'problems '()))))))
       (check-equal? code 0)
       (define r (call-with-input-file out read-json))
       (check-equal? (hash-ref r 'gate) "acceptance")
       (check-equal? (hash-ref r 'contract-version) 1)
       (check-true (hash-ref r 'ok))
       (check-false (leg-error r))
       ;; A failed doctor fails the whole report even when compliance passes.
       (define code2
         (quiet (lambda ()
                  (acceptance-command (list "--json" "--out" (path->string out))
                                      #:doctor (lambda () (hasheq 'usable #f 'problems '("x")))))))
       (check-equal? code2 1)
       (check-false (hash-ref (call-with-input-file out read-json) 'ok))))))

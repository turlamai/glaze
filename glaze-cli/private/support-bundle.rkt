#lang racket/base

;; `raco glaze support-bundle [--out FILE]` — collect a redacted
;; diagnostic ZIP (the glaze analogue of rivet's support-bundle):
;; environment facts, the doctor report, the project inspect report when
;; run inside a glaze project, and bounded window-state/log files from
;; the glaze config tree. Every string passes through home-directory
;; redaction before it enters the archive, so a bundle shared in an
;; issue does not leak the user's account name or absolute paths.

;; The doctor and inspect reports are injected by the dispatcher (cli.rkt)
;; as thunks: a private command module points inward to framework helpers
;; and must not import the aggregate package or inspect command modules
;; (module-boundaries guard).

(require json
         racket/file
         racket/list
         racket/path
         racket/string
         file/zip
         glaze/path
         glaze/private/compliance)

(provide support-bundle-command
         parse-support-bundle-opts
         redact-home
         redact-text
         redact-jsexpr
         bundle-entries
         collect-bundle-files
         write-bundle!)

;; ---- redaction (pure) ---------------------------------------------------

(define (redact-home text home)
  (define trimmed (regexp-replace #px"[/\\\\]+$" home ""))
  (define key (if (string=? trimmed "") home trimmed))
  ;; Paths reach the bundle in several spellings: native separators, the
  ;; backslash-escaped form `raco pkg show -l` prints for link targets, and
  ;; forward slashes. Redact every variant so none leaks the account name.
  (for/fold ([t text])
            ([variant
              (in-list
               (list key (string-replace key "\\" "\\\\") (string-replace key "\\" "/") home))])
    (string-replace t variant "~")))

;; Redact against several home roots. Racket's home-dir can be redirected
;; (PLTUSERHOME), so the real account profile (USERPROFILE on Windows, HOME
;; on Unix) must also be covered or paths like APPDATA leak the username.
;; Longest roots first so nested prefixes collapse cleanly.
(define (home-list home)
  (cond
    [(list? home) home]
    [(string? home) (list home)]
    [else '()]))

(define (redact-text text homes)
  (for/fold ([t text]) ([h (in-list (sort (home-list homes) > #:key string-length))])
    (redact-home t h)))

(define (redact-jsexpr v homes)
  (cond
    [(string? v) (redact-text v homes)]
    [(hash? v)
     (for/hash ([(k val) (in-hash v)])
       (values k (redact-jsexpr val homes)))]
    [(list? v) (map (lambda (x) (redact-jsexpr x homes)) v)]
    [else v]))

;; ---- collection ---------------------------------------------------------

(define max-bundle-file-bytes (* 256 1024))

;; Window-state and log files under the glaze config tree, each bounded
;; so one runaway log cannot bloat the bundle. Returns (rel-name . text)
;; pairs; unreadable files are skipped rather than failing the bundle.
(define (collect-bundle-files root)
  (define (relative-name p)
    (string-append "config/" (string-replace (path->string (find-relative-path root p)) "\\" "/")))
  (define (interesting? p)
    (or (equal? (path->string (file-name-from-path p)) "window-state.json")
        (equal? (filename-extension p) #"log")))
  (if (directory-exists? root)
      (for*/list ([p (in-directory root)]
                  #:when
                  (and (file-exists? p) (interesting? p) (< (file-size p) max-bundle-file-bytes)))
        (define text
          (with-handlers ([exn:fail? (lambda (_) #f)])
            (file->string p)))
        (and text (cons (relative-name p) text)))
      '()))

;; ---- assembly (pure over collected inputs) ------------------------------

(define (bundle-entries home environment doctor inspect files)
  (define (json-entry name v)
    (cons name (jsexpr->string (redact-jsexpr v home))))
  (append (list (json-entry "environment.json" environment) (json-entry "doctor.json" doctor))
          (if inspect
              (list (json-entry "inspect.json" inspect))
              '())
          (for/list ([f (in-list files)])
            (cons (car f) (redact-text (cdr f) home)))))

(define (write-bundle! entries out-path)
  (define staging (make-temporary-file "glaze-bundle-~a" 'directory))
  (dynamic-wind void
                (lambda ()
                  (for ([entry (in-list entries)])
                    (define p (build-path staging (car entry)))
                    (define parent (path-only p))
                    (when parent
                      (make-directory* parent))
                    (call-with-output-file p #:exists 'replace (lambda (o) (display (cdr entry) o))))
                  (parameterize ([current-directory staging])
                    (call-with-output-file
                     out-path
                     #:exists 'replace
                     (lambda (o) (zip->output (map (lambda (e) (string->path (car e))) entries) o)))))
                (lambda () (delete-directory/files staging))))

;; ---- command ------------------------------------------------------------

(define (parse-support-bundle-opts rest)
  (let loop ([args rest]
             [out #f])
    (cond
      [(null? args) (or out "glaze-support-bundle.zip")]
      [(and (equal? (car args) "--out") (pair? (cdr args))) (loop (cddr args) (cadr args))]
      [else (error 'support-bundle "unexpected argument: ~a" (car args))])))

(define (redaction-roots)
  (define (env-root key)
    (define v (getenv key))
    (and v (not (string=? v "")) v))
  (filter
   values
   (list (path->string (find-system-path 'home-dir)) (env-root "USERPROFILE") (env-root "HOME"))))

(define (support-bundle-command rest #:doctor doctor-thunk #:inspect inspect-thunk)
  (define out (parse-support-bundle-opts rest))
  (define home (redaction-roots))
  (define glaze-md (package-metadata "glaze"))
  (define environment
    (hasheq 'contract-version
            1
            'product
            "Glaze"
            'racket-version
            (version)
            'os
            (symbol->string (system-type 'os))
            'glaze-version
            (and glaze-md (hash-ref glaze-md 'version #f))
            'config-dir
            (path->string (config-dir))))
  (define doctor
    (with-handlers ([exn:fail? (lambda (e) (hasheq 'error (exn-message e)))])
      (doctor-thunk)))
  (define inspect
    (with-handlers ([exn:fail? (lambda (e) (hasheq 'error (exn-message e)))])
      (inspect-thunk)))
  (define files (collect-bundle-files (build-path (config-dir) "glaze")))
  (define entries (bundle-entries home environment doctor inspect files))
  (write-bundle! entries out)
  (printf "support bundle: ~a (~a entries, home paths redacted)\n"
          (path->string (path->complete-path out))
          (length entries))
  0)

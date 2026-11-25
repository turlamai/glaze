#lang racket/base

;; Project scaffold ownership. Keep generated files mutually consistent here:
;; entry point, agent contract, schema configuration/baseline, frontend, and
;; native acceptance script are one versioned template.

(require racket/file
         glaze/private/schema-snapshot)

(provide init-project)

(define (write-file path content)
  (call-with-output-file path (lambda (out) (display content out)) #:exists 'replace))

(define agent-instructions
  #<<AGENTS
# Glaze agent contract

Human-first. Agent-native. Local by design.

Start with `raco glaze inspect --json` and `raco glaze doctor --json`.
Run `raco glaze schema check --json` before merging an API change.

- `main.rkt` owns Racket routes, events, and native-window behavior.
- `glaze.rktd` points schema tooling at the exported route list.
- `glaze-schema.json` is a reviewed release contract; update it explicitly.
- `public/` owns the HTML/CSS/JavaScript interface.
- `public/desktop.css` keeps the toolbar and status bar fixed in the viewport;
  scroll the workspace independently. Preserve keyboard access and system colors.
- `verify.rkt` is the non-interactive native UI acceptance check.
- `dist/` is generated output; rebuild it instead of hand-editing it.
- Glaze is GUI-first. Never replace a failed WebView with a browser fallback.
- Preserve loopback-only serving, Host validation, and token protection.

Use `raco glaze dev` for the real application path, `raco glaze verify` for
title/URL/PNG evidence, and `raco glaze build` for distributable output.
AGENTS
  )

(define verification-template
  #<<VERIFY
#lang racket/base

(require racket/file
         glaze)

(define public (build-path (current-directory) "public"))
(define verdicts '())
(define-values (_kind stop)
  (run-app
   #:public-dir public
   #:title "Glaze Verification"
   #:on-ready
   (lambda (wv url)
     (define deadline (+ (current-inexact-milliseconds) 15000))
     (define loaded?
       (let loop ()
         (cond
           [(equal? (webview-title wv) "Glaze App") #t]
           [(>= (current-inexact-milliseconds) deadline) #f]
           [else (sleep 0.1) (loop)])))
     (define shot (and loaded? (webview-capture! wv)))
     (set! verdicts
           (list (cons 'page-loaded loaded?)
                 (cons 'url (equal? (webview-url wv) url))
                 (cons 'capture (and shot (file-exists? shot) (> (file-size shot) 0)))))
     (webview-close wv))))
(stop)
(for ([verdict (in-list verdicts)])
  (printf "[verify] ~a = ~a\n" (car verdict) (cdr verdict)))
(unless (and (pair? verdicts) (andmap cdr verdicts))
  (eprintf "[verify] native UI verification failed\n")
  (exit 1))
(displayln "[verify] ALL PASS")
VERIFY
  )

(define (init-project name)
  (printf "Creating Glaze project: ~a\n" name)
  (make-directory* name)
  (make-directory* (build-path name "public"))
  (write-file (build-path name "main.rkt")
              (string-append "#lang racket/base\n\n"
                             "(require racket/runtime-path\n"
                             "         glaze)\n\n"
                             "(define-runtime-path public \"public\")\n\n"
                             "(define api '())\n"
                             "(provide api)\n\n"
                             "(module+ main\n"
                             "  (run-app #:public-dir public\n"
                             "           #:api api\n"
                             (format "           #:title ~s))\n" name)))
  (write-file
   (build-path name "glaze.rktd")
   "#hasheq((schema-baseline . \"glaze-schema.json\")\n         (schema-binding . api)\n         (schema-module . \"main.rkt\"))\n")
  (write-file (build-path name "glaze-schema.json") (canonical-json-string (schema-snapshot '())))
  (write-file
   (build-path name "public" "index.html")
   "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"UTF-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n  <title>Glaze App</title>\n  <link rel=\"stylesheet\" href=\"desktop.css\">\n</head>\n<body>\n  <header class=\"toolbar\">Glaze App</header>\n  <main class=\"workspace\" tabindex=\"0\" aria-label=\"Workspace\">\n    <h1>Glaze works!</h1>\n    <p>Edit <code>public/index.html</code> to get started.</p>\n  </main>\n  <footer class=\"status\" role=\"status\">Ready</footer>\n</body>\n</html>\n")
  (write-file (build-path name "public" "desktop.css")
              ":root {\n  color-scheme: light dark;\n  font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", system-ui, sans-serif;\n  --surface: #ffffff;\n  --chrome: #f3f4f6;\n  --ink: #202124;\n  --border: #d1d5db;\n}\n@media (prefers-color-scheme: dark) {\n  :root {\n    --surface: #202124;\n    --chrome: #292b30;\n    --ink: #e8eaed;\n    --border: #484b52;\n  }\n}\n* { box-sizing: border-box; }\nhtml, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }\nbody {\n  display: grid;\n  grid-template-rows: auto minmax(0, 1fr) auto;\n  background: var(--surface);\n  color: var(--ink);\n}\n.toolbar, .status {\n  min-width: 0;\n  padding: .5rem 1rem;\n  overflow-wrap: anywhere;\n  background: var(--chrome);\n}\n.toolbar { border-bottom: 1px solid var(--border); font-weight: 600; }\n.status { border-top: 1px solid var(--border); }\n.workspace { min-width: 0; min-height: 0; overflow: auto; padding: 1rem; overflow-wrap: anywhere; }\n.workspace:focus-visible { outline: 2px solid Highlight; outline-offset: -2px; }\nh1 { margin: 0 0 .5rem; font-size: 1.5rem; }\np { margin: 0; }\n@media (forced-colors: active) {\n  .toolbar, .status { border-color: CanvasText; }\n}\n")
  (write-file (build-path name "AGENTS.md") agent-instructions)
  (write-file (build-path name "verify.rkt") verification-template)
  (printf "Done! Run:\n  cd ~a\n  racket main.rkt\n\nOr use:\n  cd ~a\n  raco glaze dev\n" name name))

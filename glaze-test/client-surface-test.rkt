#lang racket/base

;; Generated-client freshness guard — the glaze analogue of rivet's
;; `generate --check`. Glaze serves api.js / api.d.ts dynamically on BOTH
;; transports (loopback HTTP and the native scheme handler), so there is no
;; on-disk artifact to diff; the drift risk is the generators themselves
;; (the 0.18.0 api.d.ts namespace bug shipped exactly that way). This guard
;; asserts set equality between every generated client surface and the live
;; route table:
;;   - HTTP /glaze/api.js entries   == JS names of all live routes
;;   - native api.js entries        == the same set (transport parity)
;;   - HTTP /glaze/api.d.ts decls   == JS names of the TYPED live routes
;;   - native api.d.ts decls        == the same set
;; A generator that drops, renames, or duplicates an entry fails here
;; instead of shipping.

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/set
         racket/string
         net/http-client
         glaze/api
         glaze/api-macros
         glaze/bridge
         glaze/server
         glaze/private/native-client
         (only-in glaze/types GInt64 GString))

(current-glaze-error-reporter (lambda (_exn _uri) (void)))

(define-api-routes surface-api
                   [(GET "api/surface/items/:id") (item-get id) (hasheq 'id id)]
                   [(POST "api/surface/items") (item-create [name GString]) (hasheq 'name name)]
                   [(POST "api/surface/items/echo") (item-echo [n GInt64]) (hasheq 'n n)]
                   [(GET "api/surface/legacy") (legacy) (hasheq 'ok #t)])

;; Expected names derived from the LIVE route table, not from the generators.
(define expected-js (list->set (map (lambda (r) (route->js-name (route-segments r))) surface-api)))
(define expected-dts
  (list->set (map (lambda (r) (route->js-name (route-segments r)))
                  (filter route-schema surface-api))))

;; The fixture names are plain identifiers, so route->js-name and the
;; declaration renderer's js-camel-safe agree on them.
(define (first-captures pattern text)
  (for/list ([m (in-list (regexp-match* pattern text))])
    (if (list? m)
        (second m)
        (second (regexp-match pattern m)))))

(define (js-entry-names client-js)
  (list->set (first-captures #px"\n  ([A-Za-z_][A-Za-z0-9_]*): function" client-js)))

(define (dts-function-names declarations)
  (list->set (first-captures #px"function ([A-Za-z_][A-Za-z0-9_]*)\\(" declarations)))

;; ---- native transport (pure generators) ----

(define native-js (native-api-client-js surface-api))
(define native-bootstrap native-bootstrap-js)
(define native-dts (generate-api-declarations surface-api))

(test-case "native api.js entries equal the live route surface"
  (check-equal? (js-entry-names native-js) expected-js))

(test-case "native api.d.ts declarations equal the typed live surface"
  (check-equal? (dts-function-names native-dts) expected-dts))

;; ---- HTTP transport (served artifacts) ----

(define dir (make-temporary-file "client-surface-~a" 'directory))
(define-values (port shutdown) (start-server #:port 18996 #:public-dir dir #:api surface-api))

(define (fetch path)
  (define-values (status _headers in) (http-sendrecv "127.0.0.1" path #:port port #:ssl? #f))
  (check-true (and (regexp-match? #rx" 200 " status) #t) (format "~a serves 200" path))
  (port->string in))

(define http-js (fetch "/glaze/api.js"))
(define http-dts (fetch "/glaze/api.d.ts"))
(shutdown)
(delete-directory/files dir)

(test-case "HTTP api.js entries equal the live route surface"
  (check-equal? (js-entry-names http-js) expected-js))

(test-case "HTTP api.d.ts declarations equal the typed live surface"
  (check-equal? (dts-function-names http-dts) expected-dts))

(test-case "both transports generate the same client surface"
  (check-equal? (js-entry-names http-js) (js-entry-names native-js))
  (check-equal? (dts-function-names http-dts) (dts-function-names native-dts)))

(test-case "untyped routes keep a JS entry but no declaration"
  (check-true (set-member? expected-js "surfaceLegacy"))
  (check-false (set-member? expected-dts "surfaceLegacy"))
  (check-true (set-member? expected-dts "surfaceItemsEcho")))

(test-case "generated-client errors carry the bridge code on both transports"
  ;; The native client rejects with err.code from the GLZ1 envelope; the
  ;; HTTP client must parse the error envelope and attach the same code,
  ;; so app code can branch on e.code identically on either adapter.
  (check-true (and (string-contains? http-js "e.code = j.code || (j.error && j.error.code)") #t)
              "HTTP glaze.call attaches the bridge error code")
  (check-true (and (string-contains? native-bootstrap "err.code = out.error && out.error.code") #t)
              "native client attaches the bridge error code"))

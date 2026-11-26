#lang racket/base

;; Public tray API. Dispatches to a platform-specific backend based on
;; (system-type 'os):
;;   - 'windows  -> tray-windows.rkt  (Shell_NotifyIconW via ffi/unsafe)
;;   - 'macosx   -> tray-macos.rkt    (NSStatusItem via ffi/unsafe/objc)
;;   - 'unix     -> tray-linux.rkt    (libayatana-appindicator via ffi/unsafe)
;;
;; Every backend exports the SAME procedure names (make-tray, set-tooltip!,
;; set-icon!, set-menu!, close, supported?) and performs its own platform /
;; library gating. If a backend's make-tray raises (native deps missing or not
;; implemented), the dispatcher catches it, warns, and retries against the stub
;; so callers always get a usable (possibly inert) handle.
;;
;; Click events: `make-tray #:on-event` receives 'click and 'double-click
;; (Windows) or 'click (Linux AppIndicator "activate") on the tray's own
;; message-loop thread; handlers must not block. A raising handler is logged
;; and contained. On macOS the menu opens on click and no event is reported.

(require "tray-protocol.rkt")

(provide make-tray
         tray?
         tray-backend
         tray-handle
         tray-set-tooltip!
         tray-set-icon!
         tray-set-menu!
         tray-close
         tray-supported?
         ;; re-export protocol surface for menu construction
         (all-from-out "tray-protocol.rkt"))

;; A tray handle wraps the backend-specific handle together with the backend
;; tag, so `tray-backend` introspection (and tests) can tell which
;; implementation is live without poking native resources.
(struct tray (backend handle) #:transparent)

;; Pick the backend module path for the current OS.
(define (backend-module-path)
  (case (system-type 'os)
    [(windows) 'glaze/tray/tray-windows]
    [(macosx) 'glaze/tray/tray-macos]
    [(unix) 'glaze/tray/tray-linux]
    [else 'glaze/tray/tray-stub]))

;; Cached proc table for the active backend: name symbol -> procedure. We load
;; lazily on first use so requiring glaze/tray on a host platform never drags
;; in another platform's backend (which could fail at require time).
(define backend-procs #f)

(define (load-backend!)
  (unless backend-procs
    (define mod (backend-module-path))
    (define table
      (for/hash ([name (in-list '(make-tray set-tooltip! set-icon! set-menu! close supported?))])
        (values name (dynamic-require mod name))))
    (set! backend-procs table))
  backend-procs)

;; Load the stub's procs under a separate table, used for fallback.
(define (load-stub-procs)
  (define tbl (make-hash))
  (for ([name (in-list '(make-tray set-tooltip! set-icon! set-menu! close supported?))])
    ;; Stub exports use a `stub:` prefix.
    (hash-set! tbl
               name
               (dynamic-require 'glaze/tray/tray-stub (string->symbol (format "stub:~a" name)))))
  tbl)

(define (ref name tbl)
  (hash-ref tbl name))

(define (tray-supported?)
  (with-handlers ([exn:fail? (lambda (e) #f)])
    (and (not (eq? (detected-backend) 'stub)) ((ref 'supported? (load-backend!))))))

;; Dispatch by the handle's backend, never by another tray's failure.
(define (current-table t)
  (if (eq? (tray-backend t) 'stub)
      (load-stub-procs)
      (load-backend!)))

(define (make-tray #:icon icon-path
                   #:tooltip tooltip
                   #:menu items
                   #:on-event [on-event (lambda (e) (void))])
  (with-handlers ([exn:fail? (lambda (e)
                               (fprintf (current-error-port)
                                        "[glaze] tray backend unavailable (~a); using no-op stub.\n"
                                        (exn-message e))
                               (define tbl (load-stub-procs))
                               (tray 'stub
                                     ((ref 'make-tray tbl) #:icon icon-path
                                                           #:tooltip tooltip
                                                           #:menu items
                                                           #:on-event on-event)))])
    (tray (detected-backend)
          ((ref 'make-tray (load-backend!)) #:icon icon-path
                                            #:tooltip tooltip
                                            #:menu items
                                            #:on-event on-event))))

;; Backend tag for tagging purposes (does not force a reload).
(define (detected-backend)
  (case (system-type 'os)
    [(windows) 'windows]
    [(macosx) 'macos]
    [(unix) 'linux]
    [else 'stub]))

(define (tray-set-tooltip! t tooltip)
  ((ref 'set-tooltip! (current-table t)) (tray-handle t) tooltip))
(define (tray-set-icon! t icon-path)
  ((ref 'set-icon! (current-table t)) (tray-handle t) icon-path))
(define (tray-set-menu! t items)
  ((ref 'set-menu! (current-table t)) (tray-handle t) items))
(define (tray-close t)
  ((ref 'close (current-table t)) (tray-handle t)))

(module+ test
  (require rackunit)
  ;; Inject a native backend without opening a desktop window. A stub handle
  ;; must not change which table owns an already-created native handle.
  (define calls (box '()))
  (define saved backend-procs)
  (dynamic-wind
    void
    (lambda ()
      (set! backend-procs
            (hash 'set-tooltip!
                  (lambda (handle tooltip)
                    (set-box! calls (cons (list handle tooltip) (unbox calls))))
                  'close
                  (lambda (handle)
                    (set-box! calls (cons handle (unbox calls))))))
      (define native (tray 'windows 'native-handle))
      (define fallback
        (tray 'stub ((ref 'make-tray (load-stub-procs)) #:icon #f #:tooltip "stub" #:menu '())))
      (tray-set-tooltip! native "before")
      (tray-set-tooltip! fallback "ignored")
      (tray-close fallback)
      (tray-set-tooltip! native "after")
      (tray-close native)
      (check-equal? (reverse (unbox calls))
                    '((native-handle "before") (native-handle "after") native-handle)))
    (lambda () (set! backend-procs saved))))

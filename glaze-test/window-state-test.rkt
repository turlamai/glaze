#lang racket/base

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/string
         glaze/window-state
         glaze/webview/main
         glaze/private/window-state-root)

(define area (screen-area 0 0 1920 1080))

(check-equal? (normalize-window-state (window-state 100 200 800 600 #f) area)
              (window-state 100 200 800 600 #f)
              "visible geometry is unchanged")
(check-equal? (normalize-window-state (window-state 4000 3000 800 600 #t) area)
              (window-state 1120 480 800 600 #t)
              "stranded geometry is clamped onto the virtual desktop")
(check-equal? (normalize-window-state (window-state -500 -200 3000 2000 #f) area)
              (window-state 0 0 1920 1080 #f)
              "oversized geometry shrinks to the current desktop")

(define work (make-temporary-file "glaze-window-state-~a" 'directory))
(define state-path (build-path work "nested" "window.json"))
(dynamic-wind void
              (lambda ()
                (define expected (window-state -120 40 900 700 #t))
                (check-equal? (write-window-state! state-path expected) state-path)
                (check-equal? (read-window-state state-path) expected)
                (call-with-output-file state-path
                                       #:exists 'truncate/replace
                                       (lambda (output) (display "{not-json" output)))
                (check-false (read-window-state state-path) "corrupt state fails closed")
                (check-true (procedure? webview-window-state))
                (check-true (procedure? webview-set-window-state!))
                (check-true (procedure? webview-save-state!))
                (check-true (procedure? webview-restore-state!)))
              (lambda ()
                (when (directory-exists? work)
                  (delete-directory/files work))))

;; ---- glaze#131: the state root must never land in a read-only payload ----
;;
;; The packaged Linux launcher pins (find-system-path 'pref-dir) inside the
;; installed payload (/usr/lib/<app>/bin/etc/...), which is read-only for the
;; user. The pure selector is exercised for every OS so the regression fails
;; CI on any platform, not only on Linux.

;; Fixtures use complete paths of the RUNNING platform: a POSIX-style
;; literal like "/home/tester" is drive-relative (not complete) on Windows,
;; which would silently exercise the fallback branch instead of the XDG one.
(define home (find-system-path 'home-dir))
(define payload-pref (build-path home "glaze-test-payload" "bin" "etc" "racket"))
(define xdg-alt (build-path home ".config-alt"))

(test-case "window-state-root: unix prefers an absolute XDG_CONFIG_HOME"
  (check-equal? (window-state-root 'unix (path->string xdg-alt) home payload-pref) xdg-alt))

(test-case "window-state-root: unix falls back to $HOME/.config, never pref-dir"
  (for ([xdg (in-list (list #f "" "relative/path"))])
    (check-equal? (window-state-root 'unix xdg home payload-pref)
                  (build-path home ".config")
                  (format "unset/empty/relative XDG (~v) falls back to HOME/.config" xdg)))
  ;; The regression itself: even when pref-dir points into the read-only
  ;; install payload, the unix root stays user-writable (never under pref).
  (define root (window-state-root 'unix #f home payload-pref))
  (check-false (string-prefix? (path->string root) (path->string payload-pref))
               "unix root is not inside the payload pref-dir"))

(test-case "window-state-root: windows and macOS keep the historical pref-dir"
  (for ([os (in-list '(windows macosx))])
    (check-equal? (window-state-root os "/home/tester/.config-alt" home payload-pref)
                  payload-pref
                  (format "~a keeps pref-dir" os))))

(test-case "default-window-state-path: absolute, app-scoped, platform-correct root"
  (define path (default-window-state-path "com.example.app"))
  (check-true (complete-path? path) "the default state path is absolute")
  (check-equal?
   (take-right (explode-path path) 3)
   (list (string->path "glaze") (string->path "com.example.app") (string->path "window-state.json")))
  (when (eq? (system-type 'os) 'unix)
    (define root
      (window-state-root 'unix
                         (getenv "XDG_CONFIG_HOME")
                         (find-system-path 'home-dir)
                         (find-system-path 'pref-dir)))
    (check-equal? (take-right (explode-path path) 4)
                  (cons (last (explode-path root))
                        (list (string->path "glaze")
                              (string->path "com.example.app")
                              (string->path "window-state.json"))))))

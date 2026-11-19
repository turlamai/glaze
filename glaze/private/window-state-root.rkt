#lang racket/base

;; Root directory for persisted window state (glaze#131).
;;
;; On Linux the `raco exe` launcher receives payload-relative -G/-X paths,
;; so (find-system-path 'pref-dir) resolves INSIDE the installed, read-only
;; payload (<install>/bin/etc/... under /usr/lib/<app> for deb, or the
;; AppImage mount): the first state write dies with EROFS on a plain
;; `apt install` + launch. Prefer the XDG config root instead — the same
;; convention as glaze/path's config-dir — so packaged and source runs
;; agree on a user-writable location. Windows and macOS keep the historical
;; pref-dir, which is user-writable there.
;;
;; The selector is pure (os, raw XDG value, home, pref) so the regression
;; is testable on every CI platform, not only on Linux.

(require racket/path)

(provide window-state-root)

;; Per the XDG Base Directory spec, an empty or relative XDG_CONFIG_HOME
;; value is invalid and must be ignored in favor of $HOME/.config.
(define (window-state-root os xdg-config home pref)
  (if (eq? os 'unix)
      (if (and xdg-config (not (string=? xdg-config "")) (complete-path? (string->path xdg-config)))
          (string->path xdg-config)
          (build-path home ".config"))
      pref))

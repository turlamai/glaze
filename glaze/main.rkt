#lang racket/base

;; The legacy `glaze` compatibility facade. New applications import
;; `glaze/core` and the explicit reviewed layers (docs/api-stability.md).
;;
;; G3-S2 (0.18.0) internalized 22 private-tier names behind glaze/private
;; and kept them here as deprecated shims for one release cycle. That
;; window closed: the shims were removed after 0.19.0 (glaze#133). The
;; except-in clauses below stop the raw backend accessors and the
;; platform-bound default instances from leaking back through
;; all-from-out; their canonical owners still export them for expert use.

(require "server.rkt"
         "api.rkt"
         "api-macros.rkt"
         "bridge.rkt"
         "types.rkt"
         "capability.rkt"
         "filesystem.rkt"
         "shell.rkt"
         "store.rkt"
         "system.rkt"
         "path.rkt"
         "http.rkt"
         "sql.rkt"
         (except-in "global-shortcut.rkt" default-hotkey-backend)
         "log.rkt"
         "events.rkt"
         "hotkey/main.rkt"
         "sys/main.rkt"
         "update.rkt"
         "browser.rkt"
         "assets.rkt"
         "build.rkt"
         (except-in "app.rkt" app-windows app-window-count)
         (except-in "dialogs.rkt" default-dialog-backend)
         "deeplink.rkt"
         "autolaunch.rkt"
         (except-in "tray/main.rkt" tray-backend tray-handle)
         (except-in "webview/main.rkt" webview-backend webview-handle))

(provide (all-from-out "server.rkt"
                       "api.rkt"
                       "api-macros.rkt"
                       "bridge.rkt"
                       "types.rkt"
                       "capability.rkt"
                       "filesystem.rkt"
                       "shell.rkt"
                       "store.rkt"
                       "system.rkt"
                       "path.rkt"
                       "http.rkt"
                       "sql.rkt"
                       "global-shortcut.rkt"
                       "log.rkt"
                       "events.rkt"
                       "browser.rkt"
                       "assets.rkt"
                       "build.rkt"
                       "sys/main.rkt"
                       "hotkey/main.rkt"
                       "update.rkt"
                       "dialogs.rkt"
                       "deeplink.rkt"
                       "autolaunch.rkt")
         (all-from-out "app.rkt")
         (all-from-out "tray/main.rkt")
         (all-from-out "webview/main.rkt"))
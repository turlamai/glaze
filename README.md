# Glaze

Build desktop apps with a [Racket](https://racket-lang.org/) backend and a web frontend. Write your app logic in Racket, build your UI with HTML/CSS/JS, and ship a desktop application.

**Human-first. Agent-native. Local by design.**

[![CI](https://github.com/turlamai/glaze/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/glaze/actions/workflows/ci.yml) ![Racket](https://img.shields.io/badge/Racket-9F1D20?logo=racket&logoColor=white) [![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE) [![Version](https://img.shields.io/github/v/release/turlamai/glaze?label=version)](https://github.com/turlamai/glaze/releases/latest)

**English** · [中文](README.zh-CN.md)

## Start here

Choose Glaze for a Racket backend and a shared HTML/CSS/JS interface inside native system WebViews. A real desktop window is mandatory; there is no external-browser fallback. Product data/permissions and service policy remain application-owned.

[Fit, maturity, upgrades and support](docs/USING.md) · [简体中文](docs/USING.zh-CN.md)

## Why Glaze?

Racket's `racket/gui` works but is hard to style into a modern product-grade UI. Glaze takes a different approach: Racket serves the local application frontend and displays it inside a **native desktop window** backed by the OS WebView — WebView2 on Windows, WKWebView on macOS, and WebKitGTK on Linux.

You get:

- **Racket for logic** — the full power of Racket's macro system, contracts, pattern matching
- **Web for UI** — Tailwind, Svelte, React, or any web framework
- **Native desktop shell** — a real OS window with an embedded system WebView
- **Typed API bridge** — generated JavaScript invokes Racket over native GLZ1 or an explicit HTTP adapter
- **Runtime capabilities** — default-deny route permissions with path and command scopes
- **Scoped filesystem plugin** — text/binary I/O, directories, metadata, copy/move/remove
- **Scoped shell plugin** — bounded command output, timeouts, managed background processes
- **Persistent store plugin** — atomic JSON stores, debounced auto-save, change events
- **System plugins** — scoped clipboard, notifications, opener, and OS information
- **Path resolver** — app directories, resources, portable overrides, path utilities
- **Scoped HTTP client** — bounded requests, timeouts, redirect re-authorization
- **Scoped SQLite plugin** — parameterized select/execute and owned connections
- **Global shortcuts** — system-wide hotkeys with scoped accelerators and SSE triggers
- **Structured logging** — per-sink levels, rotating files, SSE push, bounded history
- **Native dialogs** — capability-gated file/folder pickers, save dialogs, and message boxes

Glaze is deliberately **GUI-first**. If the required native WebView runtime is missing or broken, startup fails with platform-specific installation/repair instructions. It does **not** silently turn the desktop app into a browser tab.

### Runtime design

Glaze embeds the platform WebView in a real desktop window, uses Racket for application logic, and provides explicit, capability-gated backend routes. The frontend-to-backend transport is native GLZ1 when selected or the HTTP adapter by default in 0.x. Missing platform WebView dependencies produce a diagnostic rather than an external browser fallback.

All three WebView backends pass the real-window CI e2e (open, load, capture, navigate, close, on-close). Native GLZ1 transport is implemented on Windows, macOS and Linux. The 0.x `run-app` default remains the HTTP adapter inside a native WebView; Linux needs a graphical session or Xvfb.

## Platform status

| Capability | macOS | Windows | Linux |
|---|---|---|---|
| Local HTTP application server | ✅ | ✅ | ✅ |
| System tray | ✅ | ✅ | ✅ (CI-verified) |
| JSON API bridge | ✅ | ✅ | ✅ |
| Capability-gated API routes | ✅ | ✅ | ✅ |
| Scoped filesystem plugin | ✅ | ✅ | ✅ |
| Scoped shell/process plugin | ✅ | ✅ | ✅ |
| Persistent key-value store plugin | ✅ | ✅ | ✅ |
| Capability-gated system plugins | ✅ | ✅ | ✅ |
| App/user/resource path resolver | ✅ | ✅ | ✅ |
| Capability-gated HTTP client | ✅ | ✅ | ✅ |
| Capability-gated SQLite plugin | ✅ | ✅ | ✅ |
| Capability-gated global shortcuts | ✅ | ✅ | ✅ X11/XWayland |
| Capability-gated structured logging | ✅ | ✅ | ✅ |
| Capability-gated native dialogs | ✅ | ✅ | ✅ zenity/kdialog |
| Native WebView window | ✅ verified end-to-end | ✅ CI e2e (WebView2) | ✅ CI e2e (Xvfb + WebKitGTK) |
| `webview-title` / `webview-url` | ✅ | ✅ | ✅ |
| `webview-capture!` (screenshot) | ✅ | ✅ (PrintWindow + PowerShell PNG) | ✅ (gdk_pixbuf) |
| `#:devtools?` | ✅ (inspectable, macOS 13+) | ✅ (`OpenDevToolsWindow`) | ✅ (WebKitGTK inspector) |
| Window geometry + persisted state | ✅ | ✅ | ✅ |

Native WebView support is mandatory for application startup. `run-app` and `open-window` never open the system browser as a fallback.

## Requirements

| Platform | Runtime requirement |
|---|---|
| All | [Racket](https://racket-lang.org/) 9.0 or later, CS runtime (includes `raco`) |
| Windows | Microsoft Edge WebView2 Runtime (Evergreen). Glaze ships `WebView2Loader.dll`; install/repair the Runtime if startup says it is unavailable. |
| macOS | WKWebView is built into macOS; run inside a logged-in graphical session. |
| Linux | GTK 3 + WebKitGTK (`libwebkit2gtk-4.1-0` on current Debian/Ubuntu; distro equivalent elsewhere) and a graphical desktop session/Xvfb. |

When startup cannot initialize the native backend, Glaze preserves the underlying backend error and adds actionable installation/repair guidance. Interactive desktop apps also attempt to show the same diagnosis in an OS-level error dialog, which matters for packaged Windows `--gui` executables that have no console. CI suppresses the dialog automatically; `GLAZE_NO_STARTUP_DIALOG=1` disables it explicitly.

## Quick Start

### 1. Install

```bash
raco pkg install --auto glaze
```

A single Racket package: this installs the `glaze` library, the `raco glaze` CLI, and the documentation (browse it later with `raco docs`).

To pin an application to a revision instead of the catalog head, use `raco glaze install <rev>`; it links the checkout under the canonical `glaze` package name and is the repair path `raco glaze doctor --fix` points to.

### 2. Create a new project

```bash
raco glaze init myapp
cd myapp
```

### 3. Run

```bash
racket main.rkt
# or
raco glaze dev
```

A native desktop window opens using the default HTTP adapter, or native GLZ1 when explicitly selected. Missing WebView runtimes produce repair guidance, never a browser fallback.

**Next:** follow the [canonical first-app tutorial](docs/getting-started.md) to add a typed Racket route, call it from JavaScript, check the schema, verify the real window, and build the app.

> Prefer installing straight from a GitHub checkout instead of the catalog?
> ```bash
> git clone https://github.com/turlamai/glaze.git
> cd glaze
> raco pkg install --auto --link "$PWD"
> ```
> To work on Glaze itself, see [CONTRIBUTING.md](CONTRIBUTING.md).

## CLI Commands

```bash
raco glaze init <name>       # Create a native Glaze desktop project
raco glaze inspect --json    # Read the project/edit/verification contract
raco glaze doctor --json     # Diagnose package and native WebView readiness
raco glaze schema write      # Explicitly refresh the application API baseline
raco glaze schema check --json # Reject breaking application API changes
raco glaze dev               # Run this project's native desktop app
raco glaze verify            # Assert title/URL and capture the native window
raco glaze measure size      # Report packaged artifact sizes against budgets
raco glaze measure startup   # Launch a packaged artifact and require survival
raco glaze build             # Build a distributable (exe + bundled assets)
raco glaze install <rev>     # Pin the glaze package to a revision and link it
raco glaze updater-keygen    # Create an Ed25519 update-signing keypair
raco glaze update-sign       # Sign an update artifact
raco glaze update-verify     # Verify an artifact and pinned-key signature
raco glaze manifest-sign     # Validate and sign a complete update manifest
raco glaze manifest-verify   # Verify a manifest signature and pinned key id
raco glaze help              # Show help
```

There is intentionally no browser-mode `dev`/`serve` command. Development and production use the same native WebView path so missing dependencies and native-backend failures cannot be hidden by a browser fallback.

`init` also creates `AGENTS.md`, `glaze.rktd`, a deterministic
`glaze-schema.json`, and a runnable `verify.rkt`. This gives coding agents
explicit edit boundaries, machine-readable inspection/diagnostics, a reviewed
application API contract, and native-window evidence with meaningful exit codes. See the
[agent-native workflow](docs/agent-native.md).

### Application schema contract

`glaze.rktd` tells the schema tool which module and exported route-list binding
to load. The generated default is equivalent to:

```racket
#hasheq((schema-module . "main.rkt")
        (schema-binding . api)
        (schema-baseline . "glaze-schema.json"))
```

Keep application startup inside `module+ main` and export the route list. This
lets CI inspect the exact GLZ1/Keel contract without opening a window or running
application startup code. `schema check` exits 1 for a compatibility break, 2
for configuration or loading errors, and 0 for compatible changes. Its JSON
report separates `breaking-changes` from `compatible-additions`. Updating a
baseline is an explicit review decision: run `schema write`, inspect the diff,
then commit it with the intentional API change.

### `build`

Package a Glaze project into a platform distribution (`raco exe` + `raco distribute`) with the frontend assets bundled alongside the executable. On macOS the distribution is a proper `.app` bundle with your `--version` stamped into `Info.plist`.

```bash
raco glaze build --name myapp
raco glaze build --name myapp --version 1.2.0 \
  --publisher "Acme Inc" --identifier com.acme.myapp --installer
```

Options: `--name`, `--version`, `--publisher`, `--identifier`, `--icon <.ico/.icns>`, `--entry <path>` (default `main.rkt`), `--out <dir>` (default `dist`), `--embed-dlls` (Windows: single-file exe), `--installer`, the signing flags `--sign <id>`, `--entitlements <plist>`, `--no-hardened-runtime`, `--notarize <profile>`, `--timestamp-url <url>`, the deep-link flag `--url-scheme <name>` (repeatable), `--dmg-background <.png>`, and the Windows wizard assets `--installer-license <.rtf>`, `--installer-banner <.bmp>` and `--installer-dialog <.bmp>`. Keep `--identifier` stable across releases: Glaze derives the WiX `UpgradeCode` and NSIS uninstall registry identity from it.

> The installer step probes for the native packaging toolchain (WiX / NSIS on Windows, `create-dmg` / `hdiutil` on macOS, `dpkg-deb` / `rpmbuild` / `appimagetool` / `linuxdeploy` on Linux) and **degrades gracefully** to a `.zip` / `.tar.gz` when that packaging toolchain is absent, printing a warning naming what to install. On Linux every available format is produced from one FHS staging tree — `/usr/lib/<app>` payload, `/usr/bin/<app>` wrapper, `.desktop` entry, and a hicolor icon — so deb, rpm, and AppImage carry identical payloads; a project without an icon still gets a valid generated placeholder. This packaging fallback is unrelated to application startup: the app itself still requires a native WebView.

### `measure`

Measure what a build actually produced instead of eyeballing `dist/`:

```bash
raco glaze measure size [--budget budgets.json] [--artifact sampleapp.dmg]
raco glaze measure startup [--artifact sampleapp.app] [--seconds 3]
```

`size` lists every artifact in bytes; with `--budget` it exits nonzero when an
artifact exceeds the first matching `{"glob": ..., "max-bytes": ...}` rule, so a
size regression fails CI. `startup` launches a packaged artifact (unwrapping a
macOS `.app` to its inner binary), requires it to stay alive for the window,
then terminates it; exiting early is an error. It measures launch survival, not
time-to-interactive, so treat the elapsed value as informational on shared
runners.

### Code signing & notarization

`build` drives `codesign` (macOS) and `signtool` (Windows); a signing failure
aborts the build, while a missing toolchain warns.

```bash
# macOS: Developer ID + hardened runtime + notarize/staple
raco glaze build --name myapp --sign "Developer ID Application: Acme Inc (TEAMID)" \
  --notarize acme-notary --installer

# macOS ad-hoc for local/CI smoke
raco glaze build --name myapp --sign -

# Windows: certificate thumbprint or subject, RFC-3161 timestamped
raco glaze build --name myapp --sign 40HEXCHARS --installer
```

`--entitlements`, `--timestamp-url` and `--no-hardened-runtime` round it out.
Certificate custody, CI secrets and verification commands:
[production signing](docs/production-signing.md).

### Product entitlements

Product licensing is intentionally outside Glaze's framework boundary. Applications that need offline-verifiable commercial entitlements can compose Glaze with [Permit](https://github.com/turlamai/permit) or another independent entitlement library; Glaze does not depend on it. Applications that need online checkout, payment-event handling, or credential delivery may additionally use [Commerce](https://github.com/turlamai/commerce) as a product/service dependency. Manual-sale and fully offline products do not need Commerce. Provider secrets, Commerce secrets, Permit signing, Glaze update signing, and platform code signing remain separate concerns and keys.

### Update integrity

`check-update` is the small notification helper. The installed updater verifies
a signed manifest and artifact, selects by channel/platform/architecture,
enforces rollout and minimum version, and runs an install plan with rollback:

```racket
(define manifest
  (fetch-update-manifest manifest-url pinned-public-key #:key-id "release-2026"))
(define candidate (select-update config manifest))
(when candidate
  (define artifact (download-update config candidate download-path))
  (execute-install-plan!
   (make-replace-install-plan candidate artifact installed-path
                              #:restart restart-app)))
```

Verification uses the pure-Racket [`ed25519`](https://pkgs.racket-lang.org/package/ed25519)
backend, so an installed application needs no OpenSSL 3 CLI; signing and key
generation still do. Every fetch is HTTPS-only across at most ten redirects.
Release automation signs the artifact and the validated manifest:

```bash
raco glaze updater-keygen --out updater-keys
raco glaze update-sign --artifact app.zip --key updater-keys/private.pem --out app.zip.sig
raco glaze update-verify --artifact app.zip --pub updater-keys/public.pem \
  --signature app.zip.sig --sha256 <manifest-sha256>
raco glaze manifest-sign --manifest manifest.json --key updater-keys/private.pem \
  --key-id release-2026 --out manifest.signed.json
raco glaze manifest-verify --manifest manifest.signed.json \
  --pub updater-keys/public.pem --key-id release-2026
```

Channels, staged rollout, rollback and per-installation evidence:
[releasing and updating applications](docs/release-and-updates.md).

## Project Structure

A new Glaze project looks like this:

```
myapp/
├── main.rkt          # Exported API plus native entry point
├── glaze.rktd        # Schema module/binding/baseline configuration
├── glaze-schema.json # Reviewed deterministic GLZ1/Keel contract
├── AGENTS.md         # Local agent contract
├── verify.rkt        # Native-window acceptance check
└── public/
    └── index.html    # Frontend
```

`raco glaze init` generates an import-safe API module whose `module+ main`
submodule is the native-window entry point. `racket main.rkt`, `raco glaze dev`,
and packaged wrappers still run the same application path, while schema tooling
can load `api` without starting the app:

```racket
#lang racket/base

(require racket/runtime-path
         glaze)

(define-runtime-path public "public")

(define api '())
(provide api)

(module+ main
  (run-app #:public-dir public
           #:api api
           #:title "myapp"))
```

`run-app` starts the local HTTP application server, opens the native WebView window, and shuts the server down when the window closes. A native-backend failure is fatal and includes dependency guidance.

## Repository Structure

One installable package at the repo root; each top-level directory is a Racket collection:

```
glaze/                # repo root = the `glaze` package (info.rkt)
├── glaze/            # Library: server, API bridge, webview, tray, sys, build, app
├── glaze-cli/        # CLI tool (raco glaze init / dev / build)
├── glaze-doc/        # Documentation (Scribble)
├── glaze-test/       # Test suite
├── examples/         # Runnable examples
└── scripts/          # CI helper scripts (webview e2e)
```

## API

### `run-app`

The one-call entry: picks a free port, starts the server (static + JSON API), opens the native WebView window, and blocks until the window closes.

```racket
(run-app #:public-dir "public"
         #:api (list (GET "api/ping" ...))
         #:capability main-capability
         #:app-id "com.example.myapp"
         #:window-state #t)
;; window closes -> server stops -> (values 'webview shutdown)
```

If native WebView startup fails, `run-app` shuts down the local server and raises the same actionable startup error. There is no `#:fallback-browser?` option.

### `start-server` / `start-dev-server`

Starts a local HTTP server serving static files with SPA fallback, plus optional JSON API routes. `start-dev-server` is a backward-compatible alias for the server primitive; it does not define Glaze's application UI mode.

```racket
(start-server #:port 8080
              #:public-dir "public"
              #:api (list (GET "api/ping" (lambda (req) (hasheq 'pong #t)))))
```

### `open-browser`

Low-level utility for opening an external URL in the user's default browser (for example, product documentation or an OAuth page). `run-app` and `open-window` do not call it as a fallback.

```racket
(open-browser "https://example.com/docs")
```

## JavaScript Bridge

The embedded frontend uses the generated, transport-neutral JavaScript client (`/glaze/api.js`, `glaze.api.*`) to invoke Racket routes. With `#:transport 'native`, GLZ1 messages cross the WebView's native message handler without exposing a loopback TCP port; with the explicit HTTP adapter, the same routes use same-origin `fetch` and can also be tested with tools such as `curl`. The [first-app walkthrough](docs/getting-started.md) shows a typed route and its generated client call.

```racket
(require glaze)

(GET  "api/ping"            (lambda (req) (hasheq 'pong #t)))
(POST "api/items/:id/bump"  (lambda (req id) (hasheq 'id id 'bumped #t)))
(POST "api/echo"            (lambda (req)
                               (define body (request-json-body req))
                               (hasheq 'echo body)))
```

- Handlers take the request plus captured `:params`; return a jsexpr (auto-wrapped as JSON 200) or a full response.
- `request-json-body` parses the JSON body — Racket jsexpr parses JSON object keys as **symbols** (`(hash-ref body 'delta)`).
- A handler that raises becomes a 500 JSON error, never a broken connection.
- Unmatched requests fall through to static files (SPA `index.html` fallback).

### Runtime capabilities and scopes

Capabilities are opt-in and strict. Once `#:capability` is supplied, every API
route must declare `#:permission`; unmarked or ungranted routes return 403 and
their handlers never run. `run-app` protects the API with a generated token by
default (`#:api-token #t`); `#:api-token #f` is an explicit opt-out, and
supplying `#:capability` requires a non-empty token. The native window obtains
the token through a one-time bootstrap URL.

```racket
(define main-capability
  (make-capability
   "main"
   (list 'settings:read
         (path-permission 'files:read
                          #:allow (list app-data-dir)
                          #:deny (list secrets-dir))
         (command-permission 'tools:run
                             #:allow '("git")
                             #:arguments (lambda (args)
                                           (equal? args '("--version")))))))

(define routes
  (list (GET "api/settings" settings-handler
             #:permission 'settings:read)
        (POST "api/files/read" read-handler
              #:permission 'files:read
              #:resource (lambda (req)
                           (hash-ref (request-json-body req) 'path)))))

(run-app #:public-dir "public" #:api routes #:capability main-capability)
```

Use `command-resource` from a route's `#:resource` procedure when enforcing a
`command-permission`. Deny paths/programs take precedence over allow entries.
Grant `'glaze:events` when an application capability should access SSE.

### Scoped filesystem plugin

`make-filesystem-routes` supplies capability-gated frontend APIs for UTF-8 text,
base64 binary files, directory listing/creation, metadata, existence checks,
file copy, move, and removal. Add its routes to the app and grant only the roots
the window needs:

```racket
(define authority
  (make-capability
   "main"
   (list (path-permission 'fs:read #:allow (list documents-dir))
         (path-permission 'fs:write #:allow (list cache-dir)))))

(run-app #:public-dir "public"
         #:api (make-filesystem-routes)
         #:capability authority)
```

The generated client exposes functions such as `glaze.api.fsReadText(body)`,
`fsWriteFile(body)`, `fsReadDir(body)`, and `fsMove(body)`. Copy and move scope
checks cover both source and destination. Writes use same-directory temporary
files followed by atomic replacement.

### Scoped shell/process plugin

`make-shell-routes` exposes direct, non-shell command execution to the frontend.
Commands and arguments are checked by `command-permission` before a process is
created. Output is bounded, synchronous calls have a timeout, and background
handles are bound to the capability that spawned them:

```racket
(define authority
  (make-capability
   "main"
   (list (command-permission
          'shell:execute
          #:allow '("git")
          #:arguments (lambda (args) (member args '(("--version") ("status")))))
         'shell:manage)))

(run-app #:public-dir "public"
         #:api (make-shell-routes)
         #:capability authority)
```

The generated client provides `glaze.api.shellOutput(body)` plus managed
`shellSpawn`, `shellStatus`, `shellWrite`, `shellCloseStdin`, and `shellKill`
calls. Programs are executed directly rather than through `cmd.exe` or
`/bin/sh`; no shell interpolation or expansion is performed. Frontend `cwd`
roots and environment-variable names are denied by default and can be
explicitly allowed with `#:cwd-roots` and `#:allow-environment`. Retained
stdout/stderr default to 1 MiB per stream, and the handle registry is bounded.

### Persistent store plugin

`make-store-routes` provides the Tauri-style persistent key-value lifecycle:
load/close, get/set/has/delete, clear/reset, keys/values/entries/length,
reload, and explicit save. Stores are JSON, writes are atomic, and auto-save is
debounced by 100 ms by default (`#f` disables it):

```racket
(define bus (make-event-bus))
(define authority
  (make-capability
   "main"
   (list (path-permission 'store:read #:allow (list app-data-dir))
         (path-permission 'store:write #:allow (list app-data-dir))
         'glaze:events)))

(run-app #:public-dir "public"
         #:api (make-store-routes #:root app-data-dir #:events bus)
         #:events bus
         #:capability authority)
```

With `#:root`, frontend paths are relative and traversal outside the configured
root is rejected independently of the capability check. Generated functions
include `storeLoad`, `storeGet`, `storeSet`, `storeEntries`, `storeReset`,
`storeSave`, `storeReload`, and `storeClose`. Mutations publish
`store:change` over the existing SSE event bus when `#:events` is supplied.

### Application paths

`make-path-resolver` provides the Tauri-style config/data/local-data/cache/log
directories namespaced by the application identifier, plus user, temporary,
font, template, executable, and resource locations. Linux user directories
honor `user-dirs.dirs`. A single portable root or per-directory
overrides are supported:

```racket
(define paths
  (make-path-resolver
   "com.example.app"
   #:resource-root bundled-assets
   #:app-directories-override (hasheq 'data "$DOCUMENT/My App"
                                       'cache "$CACHE/my-app")))

(define settings-root (app-data-dir paths))
(define icon-path (resolve-resource paths "icons/app.png"))
```

`make-path-routes` exposes independently permissioned directory queries and
`join`, `resolve`, `normalize`, `basename`, `dirname`, `extname`, and
`is-absolute` utilities to the generated frontend client. Resource resolution
rejects absolute paths, `..` traversal, and existing symlink escapes. Override
variables include `$AUDIO`, `$CACHE`, `$CONFIG`, `$DATA`, `$LOCALDATA`,
`$DESKTOP`, `$DOCUMENT`, `$DOWNLOAD`, `$HOME`, `$PICTURE`, `$PUBLIC`, `$TEMP`,
and `$VIDEO`.

### Scoped HTTP client

`http-request` provides bounded HTTP/HTTPS access to Racket code. For the
embedded frontend, `make-http-routes` adds `glaze.api.httpRequest(body)` and
requires the URL-scoped `http:request` permission:

```racket
(define authority
  (make-capability
   "main"
   (list (url-permission
          'http:request
          #:allow (list #px"^https://api\\.example\\.com/v1/")))))

(run-app ...
         #:api (make-http-routes #:timeout 15
                                 #:max-response-bytes (* 2 1024 1024))
         #:capability authority)
```

The client accepts text or base64 request bodies and returns status, final URL,
headers, `bodyText`, and `bodyBase64`. Request and response sizes, total timeout,
and redirect count are bounded. Every redirect target is authorized before the
connection is made; cross-origin redirects drop `Authorization` and `Cookie`.
Connection-managed headers such as `Host` and `Content-Length` cannot be
overridden by the frontend.

### Scoped SQLite

`open-sqlite-database`, `sql-select`, `sql-execute!`, and `sql-close!` provide
the direct Racket API. `make-sql-routes` adds `sqlLoad`, `sqlSelect`,
`sqlExecute`, and `sqlClose` to the generated client:

```racket
(define database-root (app-data-dir paths))
(define authority
  (make-capability
   "main"
   (list (path-permission 'sql:load #:allow (list database-root))
         (path-permission 'sql:select #:allow (list database-root))
         (path-permission 'sql:execute #:allow (list database-root))
         (path-permission 'sql:close #:allow (list database-root)))))

(run-app ...
         #:api (make-sql-routes #:root database-root)
         #:capability authority)
```

Frontend paths are relative to the configured root and cannot escape through
`..` or existing symlinks. Connections are cached by capability and path, and
the bounded registry prevents one frontend from consuming unlimited handles.
Queries use positional parameters; `sqlSelect` only accepts `SELECT`/`WITH`
queries and enforces a row limit. Binary values use `{ "blobBase64": "..." }`
and SQL NULL maps to JSON `null`.

### Global shortcuts

`hotkey-register!`/`hotkey-unregister!`/`hotkey-registered?` drive the native
backends directly (Win32 `RegisterHotKey`, Carbon `RegisterEventHotKey`, X11
`XGrabKey`). `make-global-shortcut-routes` adds the Tauri-style frontend API,
and `accelerator-permission` scopes which combinations a page may grab:

```racket
(define authority
  (make-capability
   "main"
   (list (accelerator-permission 'global-shortcut:register
                                  #:allow '("CmdOrCtrl+Shift+D"))
         (accelerator-permission 'global-shortcut:unregister
                                  #:allow '("CmdOrCtrl+Shift+D")))))

(run-app ...
         #:api (make-global-shortcut-routes #:events bus)
         #:events bus
         #:capability authority)
```

Accelerators use Tauri spellings (`CmdOrCtrl+Shift+D`, `KeyD`, `Digit7`, F1–F24,
numpad keys); scopes match the canonical form on both the declared and the
requested side, so case and alias variants cannot widen a grant. Triggers reach
the page as `global-shortcut` SSE events carrying the canonical accelerator:
`glaze.on('global-shortcut', ({accelerator}) => ...)`. On Linux the backend
grabs through X11, so XWayland sessions work while a Wayland session without
X reports registration failure instead of raising.

### Structured logging

One logger fans records out to sinks, each with its own minimum level:

```racket
(define logger
  (make-glaze-logger #:min-level 'info
                     #:file-root (app-log-dir paths)
                     #:events bus))

(log-info logger "server started" #:data (hasheq 'port 8080))
(log-error logger "handler failed" #:data (hasheq 'message "..."))
```

The default stderr sink always runs; `#:file-root` adds a rotating file sink
(rotation, not truncation, so a crash mid-write never destroys earlier logs),
`#:events` pushes each record to the page as a `log` SSE event, and custom
sinks (procedures or `log-sink` values) plug in through `#:sinks`. A bounded
in-memory history backs `make-log-routes`, whose `logWrite` and `logHistory`
generated functions are gated by `log:write` and `log:read`. Frontend records
carry their source and capability ID — a page cannot forge backend log lines —
and respect the logger's minimum level exactly like backend records.

### Typed routes, one declaration — `define-api-routes`

```racket
(define-api-routes api
  [(POST "api/counter/bump")
   (bump [delta exact-nonnegative-integer? 1])
   (hasheq 'count (add1 delta))])
```

One clause defines a Racket procedure, a validated HTTP route, and a JS client entry exposed by `/glaze/api.js`.

### Backend → frontend push (SSE)

```racket
(define bus (make-event-bus))
(start-server ... #:events bus)
(bus-broadcast! bus 'count-changed (hasheq 'count 42))
```

```js
glaze.on('count-changed', s => render(s.count));
```

The event stream uses the same local origin as the embedded WebView frontend.

### Security

- Requests are only served for Host headers `127.0.0.1` / `localhost` / `[::1]`.
- API handler parameter errors become 400 JSON; handler exceptions become 500 JSON and reach `run-app`'s `#:on-error` hook.
- `#:api-token` (default `#t`) protects API routes and SSE; `#:api-token #f` is the explicit opt-out and cannot be combined with `#:capability`. The native app window uses a one-time bootstrap URL to obtain an HttpOnly cookie; programmatic clients use `X-Glaze-Token`.
- Optional `#:capability` enables default-deny runtime authority. Declared route permissions may be unscoped, path-scoped, or command/argument-scoped; denied handlers are never invoked.
- Update checks remain opt-in through `run-app #:check-update ...`.
- Report suspected vulnerabilities privately through [SECURITY.md](SECURITY.md); it records the trust model, the security-sensitive owners and what is out of scope.

## System Integrations (`glaze/sys`)

```racket
(require glaze/sys)
(clipboard-set! "hello")
(notify! "Download finished" "report.pdf is ready")
(open-path "/Users/me/report.pdf")
(reveal-path "/Users/me/report.pdf")
(unless (single-instance? "com.me.app") (exit 0))
```

The same desktop features are available to the embedded frontend through
`make-system-routes`. Every operation remains default-deny: clipboard read and
write are separate permissions, notifications require `notification:send`,
file opening/reveal uses path scopes, URLs use exact or regular-expression
scopes, and hostname access is separate from ordinary OS information:

```racket
(define authority
  (make-capability
   "main"
   (list 'clipboard:write
         'notification:send
         'os:read
         (path-permission 'opener:open-path #:allow (list documents-dir))
         (url-permission 'opener:open-url
                         #:allow (list #px"^https://docs\\.example\\.com/")))))

(run-app ...
         #:api (make-system-routes)
         #:capability authority)
```

The generated client includes `systemClipboardRead`, `systemClipboardWrite`,
`systemNotificationSend`, `systemOpenerOpenPath`, `systemOpenerRevealPath`,
`systemOpenerOpenUrl`, `systemOsInfo`, and `systemOsHostname` when their
permissions are granted.

Window controls include `webview-set-title!`, `webview-set-size!`, `webview-set-fullscreen!`, and `webview-focus!`. `webview-window-state` / `webview-set-window-state!` expose outer position, size, and maximized state on every backend. Opt into automatic close/save + launch/restore with `run-app #:app-id "com.example.app" #:window-state #t`, or pass an explicit state path. Restored geometry is clamped to the current virtual desktop so unplugging a monitor cannot strand the window off-screen.

## System Tray

Glaze provides a cross-platform system tray:

- **Windows** — `Shell_NotifyIconW`
- **macOS** — `NSStatusItem` / `NSMenu`
- **Linux** — `libayatana-appindicator` + `libgtk-3`

The tray is an optional integration. If its backend is unavailable it may degrade to an inert stub; that is intentionally different from the mandatory main WebView.

## App Platform APIs

```racket
(require glaze)

(define f (pick-file #:title "Open report" #:filters '(("Reports" "*.rep" "*.csv"))))
(define dir (pick-folder #:title "Where?"))
(define out (save-file-dialog #:title "Save as" #:default-name "out.rep"))

(webview-set-menu! wv
  (list (make-menu "File"
                   (list (make-menu-item "Open…" #:accel "CmdOrCtrl+O"
                                         #:action open-doc)
                         menu-separator
                         (make-menu-item "Quit" #:action (lambda () (exit 0)))))))

(ensure-url-scheme! "myapp")
(auto-launch-set! "MyApp" #t)
(auto-launch-enabled? "MyApp")

(for ([w (all-webviews)]) (webview-focus! w))
(wait-for-webviews)
```

## Examples

| Example | What it shows |
|---|---|
| [`examples/taskboard/`](examples/taskboard/) | **Product-level example (start here)** — typed routes, persisted store, SSE, tests and native acceptance |
| [`examples/showcase/`](examples/showcase/) | **Kitchen sink** — every capability in one native window |
| [`examples/hello/`](examples/hello/) | Minimal native app — `run-app` in 8 lines |
| [`examples/counter/`](examples/counter/) | JS↔Racket bridge — `fetch` calls Racket state |
| [`examples/webview-demo.rkt`](examples/webview-demo.rkt) | Cross-platform native WebView lifecycle: load, navigate, close, verification APIs |
| [`examples/agent-verify.rkt`](examples/agent-verify.rkt) | Agent workflow: assert page state + screenshot with no human |
| [`examples/tray-demo.rkt`](examples/tray-demo.rkt) | Cross-platform system tray with a working menu |

## Testing

```bash
raco test glaze-test/                       # framework suite
racket scripts/webview-e2e.rkt              # real native window on this OS
raco make glaze/main.rkt glaze-cli/cli.rkt  # compile public entry points
```

The framework suite is windowless on Windows and Linux and also drives real
WKWebView windows on macOS. The e2e opens a native window on every OS and
needs a graphical session (Xvfb on Linux). Generated projects run their own
`verify.rkt` with `raco glaze verify`.

CI runs both on Windows, macOS and Linux, and a package job builds and
validates the installers. Application-side gates, runner requirements and
evidence: [CI contract](docs/ci.md).

## Honest gaps

- **Pre-1.0 public API** — module tiers and export lists are snapshot-checked ([API stability](docs/api-stability.md)), but names may still change with a CHANGELOG migration note.
- **Native transport is opt-in in 0.x** — `run-app` still defaults to `#:transport 'http` inside the native window. Packaged products should pass `#:transport 'native`; the 1.0 plan makes the default change a release gate that needs packaged release-candidate evidence, not a completed switch.
- **Linux qualification is bounded** — CI proves Xvfb + WebKitGTK window behavior and deb/rpm/AppImage metadata on Ubuntu. Real distribution and desktop behavior (GNOME/KDE, Wayland compositors, scaling, portals, IME) belongs to each product's release evidence. Native dialogs need `zenity` or `kdialog`; global shortcuts are X11/XWayland-only.
- **macOS needs an interactive session** — WKWebView startup requires a logged-in graphical desktop; headless or SSH sessions fail with guidance instead of falling back to a browser.
- **Windows needs the WebView2 Runtime** — Glaze stages `WebView2Loader.dll`, not the Evergreen Runtime. A missing Runtime is diagnosed at startup.
- **Windows ARM64 has its own loader** — Glaze ships both `win-x64` and `win-arm64` `WebView2Loader.dll` and selects by the Racket process architecture; CI runs native arm64 on an ARM64 host. The x64 build still runs under emulation on ARM64.
- **Intel macOS CI is build-only** — the hosted Intel runner has no WindowServer session, so CI proves the native x64 build and package path but cannot open a real window. Run the window tests on a desktop Intel Mac or a self-hosted runner.
- **Installer toolchains are external** — WiX for MSI, macOS tooling for dmg/notarization, dpkg/rpm/AppImage tooling on Linux. `--installer` falls back to zip/tar.gz with a warning when a toolchain is absent; that is a distribution-format downgrade, not a UI runtime fallback.
- **Accessibility and IME are application-owned** — Glaze hosts the system WebView and adds no accessibility layer. Semantic HTML, focus order, names/roles, large text and IME behavior must be designed and tested by the product on each platform.
- **No mobile targets** — Windows, macOS and Linux desktops only.
- **Budgets are first-pass** — `examples/showcase/budgets.json` records generous initial ceilings, not performance promises. Shared-runner measurements are informational; gates come from dedicated hardware history.
- **No independent security audit** — see [SECURITY.md](SECURITY.md).

## Roadmap

- [x] **Phase 1** — Local HTTP server + early browser prototype
- [x] **Phase 2** — Frontend asset bundling, system tray, app packaging
- [x] **Phase 3** — Native WebView embedding (WebView2 / WKWebView / WebKitGTK) — verified by the 3-OS CI e2e
- [x] **GUI-first contract** — native WebView required; actionable failure instead of browser fallback

## License

Licensed under the [MIT License](LICENSE).

Chinese onboarding: [完整中文入门](docs/getting-started.zh-CN.md); the English tutorial remains [Getting started](docs/getting-started.md).

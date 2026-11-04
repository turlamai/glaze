# Diagnosing a Glaze application

This page is the troubleshooting owner for runtime and project-level failures.
The agent loop and the JSON contracts are described in
[agent-native development](agent-native.md); the GUI-first rule and startup
failure behavior are owned by [the GUI-first contract](gui-first.md).

Start with the two read-only reports:

```bash
raco glaze doctor --json    # package table, collection resolution, WebView, project schema; nonzero on problems
raco glaze inspect --json   # project contract, expected files, schema status, native backend
```

Both write one JSON object and never open a window. `doctor --fix` removes
broken or legacy package links, then asks you to reinstall; it is incompatible
with `--json`.

## Symptom to cause

| Symptom | First check | Usual cause and fix |
| --- | --- | --- |
| Startup fails with “native WebView unavailable” | `doctor --json` → `webview.supported` and `webview.diagnostic` | The platform runtime is missing or broken. Install WebView2 Runtime (Windows), run in a logged-in macOS session, or install GTK 3 + WebKitGTK and a display server (Linux). |
| An OS error dialog blocks an unattended job | environment | Set `GLAZE_NO_STARTUP_DIALOG=1`. The dialog is only for interactive desktops; the underlying failure is unchanged. |
| `doctor` reports a link to a missing path | `doctor` output | A checkout moved or was deleted. `raco glaze doctor --fix`, then `raco glaze install <rev>`. |
| `doctor` reports a non-canonical owner | `doctor` output | A link install is named after its directory (`glaze-src`, `glaze-pinned`) and owns glaze files. Remove it and reinstall with `raco glaze install <rev>`. |
| `doctor` reports the collection does not resolve | `doctor` output | Glaze is not installed or another package shadows the collection. Reinstall the package. |
| `inspect` schema status is not `ready` | `inspect.schema.status` | `missing-config` (no `glaze.rktd`), `missing-schema-module` (no `schema-module`), `missing-module`, `missing-baseline`, `invalid-config` (the config is not exactly one hash datum), or `ready`. |
| `schema check` fails | its JSON reasons | A route, parameter, type, error or ordering change broke the committed baseline. Decide whether the change is intended; only then run `schema write`. |
| `verify` reports `page-loaded = #f` | `verify.rkt` and the page title | The page never reached the title the verifier waits for. The generated verifier expects `Glaze App`; if you changed `<title>`, update `verify.rkt` with your own first-run assertion. |
| `verify` reports `url = #f` | `verify.rkt` | The window navigated away from the bootstrap URL, or the application closed/reopened the window during verification. |
| `verify` reports `capture = #f` | session and backend | No graphical session, or the platform capture backend is unavailable. Run interactively or under Xvfb; a capture failure is not a pass. |
| Linux window opens but the page is blank | terminal output | Check the WebKitGTK version (4.1 packages) and try `WEBKIT_DISABLE_DMABUF_RENDERER=1` on GPU-less or remote sessions. |
| Linux native dialogs do nothing | `zenity` / `kdialog` on `PATH` | Glaze has no built-in file dialog on Linux; install one of those tools. |
| Global shortcut does nothing on Linux | session type | Global shortcuts are X11/XWayland-only. A pure Wayland session is not covered. |
| Windows build starts but the window is blank | staged `WebView2Loader.dll` and the Runtime | The loader ships with the packaged app; the Evergreen **Runtime** is a separate system dependency. `doctor` distinguishes them. |
| Packaged macOS app behaves differently from `racket main.rkt` | signing and bundle metadata | Bundle activation and lifecycle differ from a bare Racket process. Verify both paths after backend changes. |
| API requests return 401/403 | request headers and capability policy | The HTTP adapter requires `X-Glaze-Token` (or the bootstrap cookie); a denied capability is a policy decision, not an authentication failure. |
| Build warns and emits zip/tar.gz instead of an installer | toolchain availability | WiX (Windows), macOS dmg tooling, or dpkg/rpm/AppImage tooling is missing. This is a distribution-format downgrade; install the toolchain before releasing. |
| Update verification fails | manifest, key id, SHA-256 and signature | Treat it as a failed update, never as “unverified but acceptable”. Check the pinned public key, `#:key-id`, channel and artifact digest. |

## WebView diagnostics API

The public WebView layer exposes the same facts the CLI reports:

- `webview-supported?` — non-throwing capability probe;
- `webview-diagnostic` — the last startup/probe error plus platform install guidance;
- `webview-last-error` — the raw error, when one exists;
- `webview-install-guidance` — the platform-specific repair instructions.

`run-app` fails closed: a WebView that cannot start aborts startup with that
guidance and never opens a browser tab. If `run-app` had already started the
local server, it shuts the server down before raising.

## Logs

`glaze/log` provides a structured logger with per-sink levels, a rotating file
sink, an in-memory history and an SSE sink. Application routes can be exposed
through `make-log-routes` under a capability; frontend records are tagged with
their source and capability so a page cannot forge backend lines. Prefer
`log-error`/`log-warn` with structured `#:data` over `displayln` when a failure
must be reportable.

## Reporting a defect

Include the `doctor --json` and `inspect --json` output (redact paths if
needed), the Racket and Glaze versions, OS/architecture, whether the window or
the packaged artifact failed, and the first error. Report suspected
vulnerabilities privately through [SECURITY.md](../SECURITY.md).

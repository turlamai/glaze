# Diagnosing a Glaze application

This page is the troubleshooting owner for runtime and project-level failures.
The agent loop and the JSON contracts are described in
[agent-native development](agent-native.md); the GUI-first rule and startup
failure behavior are owned by [the GUI-first contract](gui-first.md).

Start with the two read-only reports:

```bash
raco glaze doctor --json    # package table, collection resolution, WebView; nonzero on package/WebView problems
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

## Collecting a support bundle

```bash
raco glaze support-bundle --out glaze-support-bundle.zip
```

This writes one ZIP with `environment.json` (Racket/Glaze versions, OS,
config root), `doctor.json` (the same report as `doctor --json`),
`inspect.json` when run inside a glaze project, and bounded
`window-state.json` / `*.log` files from the glaze config tree. Every string
is redacted against the real account profile (`USERPROFILE` on Windows,
`HOME` on Unix) in native, backslash-escaped, and forward-slash spellings,
so the archive is safe to attach to a public issue without leaking the
username or absolute paths. Attach it instead of pasting raw reports.

## License compliance

```bash
raco glaze compliance --json --out dist   # SBOM + notices + license audit
```

Generates a CycloneDX 1.5 SBOM (`glaze-sbom.cdx.json`) and third-party
notices (`glaze-notices.txt`) for the installed dependency closure and
audits every license. It exits nonzero on any rejected (strong-copyleft /
source-available) or unknown license, so CI and the source release block on
an unreviewed dependency. The Racket main distribution inherits its
Apache-2.0 OR MIT baseline; a chosen catalog dependency with no declared
license fails closed. The same gate runs in package CI and ships the SBOM +
notices as release assets.

## Cross-platform acceptance evidence

```bash
raco glaze acceptance --json --out acceptance.json   # one platform's evidence
raco glaze matrix acceptance-linux.json acceptance-windows.json acceptance-macos.json
```

`acceptance` runs the headless gates that are meaningful on any OS (doctor
usability and the compliance license audit) and writes one bounded,
self-describing report (`contract-version`, `product`, `gate`, `platform`,
`ok`, `checks`). `matrix` folds the per-platform reports into the G4
cross-platform conformance matrix and exits nonzero unless every leg passed
and every report was well-formed — a failed leg, a malformed or unreadable
report, conflicting duplicate legs, or no evidence at all all fail closed.
The packaged coldsmoke acceptance report carries the same envelope, so it
folds as an additional gate. Package CI emits one report per platform and a
`matrix` job folds them into the `glaze-acceptance-matrix` artifact.

## Where the rules live

Startup failure behavior and the never-fall-back rule are owned by
[the GUI-first contract](gui-first.md); the `webview-supported?`,
`webview-diagnostic`, `webview-last-error` and `webview-install-guidance`
procedures are documented in the Scribble manual. Structured logging and the
`make-log-routes` sink are owned by the README's logging section.

## Reporting a defect

Attach a `raco glaze support-bundle` ZIP (it already redacts home paths and
bundles the `doctor`/`inspect` reports, versions, and OS), plus whether the
window or the packaged artifact failed and the first error. If you paste
reports manually instead, include `doctor --json` and `inspect --json`, the
Racket and Glaze versions, and OS/architecture, and redact paths yourself.
Report suspected vulnerabilities privately through [SECURITY.md](../SECURITY.md).

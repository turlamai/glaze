# Taskboard

A maintained product-level Glaze example: one Racket contract, one HTML/JS
interface, a real persisted task list, and evidence that the app actually
runs. It is deliberately smaller than [`showcase/`](../showcase/) and more
complete than [`counter/`](../counter/).

## What it demonstrates

- **Typed routes** — `define-api-routes` declares `tasks`, `tasksCreate`,
  `tasksToggle`, `tasksDelete` and `tasksClearDone`; the same declaration
  produces the Racket procedures, the HTTP routes and the generated
  `glaze.api.*` client.
- **Persisted store** — `glaze/store` keeps tasks in `tasks.json` with atomic
  writes and debounced auto-save; the page never receives a filesystem path.
- **Event push** — every mutation broadcasts a fresh snapshot on the bus, so a
  second window or a reloaded page converges without polling.
- **Lazy startup** — the store opens on first request, so `raco glaze schema
  check` and `raco glaze inspect` can load `main.rkt` without touching user
  data.
- **Acceptance and tests** — `verify.rkt` opens the real WebView; the
  windowless tests cover the pure domain, persistence and the live routes.

## Run it

```bash
racket main.rkt
# or, from this directory:
raco glaze dev
```

The app requires a working native WebView (WebView2 on Windows, WKWebView on
macOS, WebKitGTK on Linux). There is no browser fallback; a missing runtime
fails with platform-specific guidance.

## Verify and test

```bash
raco glaze schema check --json     # route contract matches glaze-schema.json
raco glaze verify                  # real window: title, URL, PNG capture
raco test tests/*.rkt              # domain + store + live HTTP route tests
```

`verify` is the baseline native check, not proof of the product flow. The API
test (`tests/api-test.rkt`) starts the real server on a loopback port with a
disposable data directory and exercises create, toggle, delete, authentication
and the 400 path. On Linux run the windowed command under `xvfb-run -a`.

## Build and ship

```bash
raco glaze build --name taskboard --version 0.1.0 \
  --publisher "Turing Lambda" --identifier com.turlamai.taskboard \
  --installer --sign -
```

Keep `--identifier` stable across releases; it derives the MSI `UpgradeCode`.
Ad-hoc signing (`--sign -`) is for local builds and CI smoke, not distribution.
The example uses the 0.x default HTTP transport; packaged products should add
`#:transport 'native` to `run-app` once they have packaged-native evidence.

## Data

Tasks live in the platform application-data directory for
`com.turlamai.taskboard`:

| Platform | Location |
| --- | --- |
| macOS | `~/Library/Application Support/com.turlamai.taskboard/tasks.json` |
| Windows | `%APPDATA%\com.turlamai.taskboard\tasks.json` |
| Linux | `$XDG_DATA_HOME/com.turlamai.taskboard/tasks.json` (or `~/.local/share/...`) |

Set `TASKBOARD_DATA_DIR` to point at another directory; `verify.rkt` and the
API test use a disposable one so acceptance runs never modify a real task list.
Deleting `tasks.json` resets the board.

## Acceptance scenarios

| Scenario | Initial state | Action | Visible result | Persisted effect | Failure/recovery |
| --- | --- | --- | --- | --- | --- |
| First task | Empty board | Type a title, press Enter | Task appears; counts update to 1 open | `tasks.json` gains the task | Blank title shows an inline error and does not write |
| Toggle | One open task | Click the checkbox | Title gets struck through; done count rises | `done` flips in the store | A failed request shows an error and keeps the previous list |
| Delete | One task | Click Delete | Row disappears; counts update | Task removed from `tasks.json` | A failed request leaves the row in place |
| Restart | Existing tasks | Close and reopen | Same tasks and counts | Store reloads from disk | A corrupt file is reported; the app does not silently discard tasks |
| Filter | Mixed tasks | Click Open / Done | Only matching rows are shown | No write (view-only) | — |
| Clear done | Some done tasks | Click Clear done | Done rows disappear | Done tasks removed | No done tasks shows an informational message |

## Files

```text
taskboard/
├── main.rkt            # routes, store wiring, run-app, exports for verify
├── taskboard.rkt       # pure domain (add/toggle/remove/stats), no I/O
├── verify.rkt          # native-window acceptance check
├── glaze.rktd          # schema module/binding/baseline
├── glaze-schema.json   # reviewed route contract
├── public/             # index.html, app.js, styles.css (no build step)
└── tests/              # domain, store, and live-route tests
```

## Where to go next

- [Product acceptance](../../docs/product-acceptance.md) — what evidence a
  packaged app needs beyond `verify`.
- [CI contract](../../docs/ci.md) — gating the example on all three platforms.
- [Diagnostics](../../docs/diagnostics.md) — when the window or the store fails.

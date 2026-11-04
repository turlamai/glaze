# GLZ1 wire protocol

**Status:** a client-implementer summary. The normative contract — version
rules, Racket API, error helpers and streaming semantics — is the
[GLZ1 section of the manual](../glaze-doc/scribblings/glaze.scrbl); if this page
and the manual disagree, the manual and the tests in `glaze-test/bridge-test.rkt`
and `glaze-test/native-transport-test.rkt` win.

Use this page when writing a non-JavaScript client or debugging the frames
between the page and Racket.

## Carriers

| Carrier | Entry points | Trust boundary |
| --- | --- | --- |
| HTTP adapter (0.x default) | `GET /glaze/hello`, `POST /glaze/invoke`, `POST /glaze/cancel` on loopback | API token (`X-Glaze-Token` or the HttpOnly bootstrap cookie) plus Origin/`Sec-Fetch-Site` checks |
| Native transport | The WebView message handler named `glz1`; no TCP listener | The message handler itself; capability policy still applies |

Both carriers deliver the same JSON envelopes. The native carrier also serves
application resources from a controlled `glaze://app/` origin (WKWebView,
WebKitGTK) or WebResourceRequested (WebView2).

## Invoke envelope

```json
{"glz": 1, "id": "req-1", "path": "api/tasks",
 "method": "POST", "args": {"title": "Write docs"}, "timeout_ms": 5000}
```

| Field | Required | Rule |
| --- | --- | --- |
| `glz` | yes | Protocol version; currently `1`. An unknown version answers `unsupported-version`. |
| `id` | yes | Non-empty string; the same id appears in the response and in cancel. |
| `path` | yes | Non-empty route path without a leading slash, e.g. `api/tasks`. |
| `method` | no | One of `GET`, `POST`, `PUT`, `DELETE` (case-insensitive). Omitted means any registered method. |
| `args` | no | JSON object; omitted means `{}`. Non-object args are `bad-envelope`. |
| `timeout_ms` | no | Positive integer; the caller stops waiting and receives `timed-out`. There is **no server-side default timeout**. |

A malformed envelope answers `bad-envelope`; a version mismatch answers
`unsupported-version`; both are terminal responses with the same `id` when one
was parseable.

## Responses

Success:

```json
{"glz": 1, "id": "req-1", "ok": true,
 "outcome": "succeeded", "value": {"tasks": []}}
```

Failure:

```json
{"glz": 1, "id": "req-1", "ok": false,
 "outcome": "failed",
 "error": {"code": "invalid-args", "message": "...", "data": null}}
```

`outcome` is one of `succeeded`, `failed`, `cancelled`, `timed-out`. The error
object uses Keel's structured-error shape: a kebab-case `code`, a message and
JSON `data`. The closed code set is:

`unsupported-version`, `bad-envelope`, `unknown-command`, `method-not-allowed`,
`invalid-args`, `token-required`, `capability-denied`, `timed-out`,
`cancelled`, `internal`.

Clients should branch on `ok`/`outcome` and `error.code`, not on an HTTP status
line: the HTTP adapter maps codes to statuses, the native carrier has no
status line.

## Cancel

```json
{"glz": 1, "id": "req-1"}
```

`POST /glaze/cancel` (or the native `op: "cancel"` message) signals the
request table and answers `{"glz":1,"id":"req-1","ok":true,"value":"cancel-signalled"}`.
Cancellation is cooperative: a handler observes it through
`bridge-cancel-event`/`bridge-cancelled?` and should answer `cancelled`.
Cancelling an unknown id is not an error the caller can act on.

## Streaming

A streaming response is a frame sequence for the invoking id:

| Frame | Wire shape |
| --- | --- |
| Open | `{"glz":1,"stream":"open","id":"req-1"}` |
| Chunk | `{"glz":1,"stream":"chunk","id":"req-1","text":"..."}` |
| End | `{"glz":1,"stream":"end","id":"req-1"}` |

In evaluateJavaScript-style hosts the same frames arrive as calls to
`window.__glz1StreamOpen(id)`, `window.__glz1Chunk(id, text)` and
`window.__glz1End(id)`. Chunks are UTF-8 safe: a multi-byte character split
across internal reads is held until complete. Streams have no timeout; a
writer error still produces the terminal frame.

## Events

Server-push events are a batch of `(seq, name, data)` tuples:

```json
{"glz": 1, "events": [[7, "tasks-changed", {"tasks": []}]]}
```

The page receives them through `window.__glz1Events(batchJson)`; the HTTP
adapter uses SSE on the same origin. `seq` is monotonic per bus, so a client
can detect a dropped batch instead of silently rendering stale state.

## Hello

`GET /glaze/hello` answers:

```json
{"glz": 1, "name": "glaze", "app": "com.example.app",
 "routes": [{"method": "GET", "path": "/api/tasks"}],
 "schema": { "...": "Keel app-schema" }}
```

`routes` is the raw surface; `schema` is the same surface rendered as a Keel
app-schema (commands, parameters, result types, named records/enums, error
codes). Clients should prefer `schema` when they need types and treat `routes`
as the routing table.

## Compatibility

`glz` is the protocol version, independent of the Glaze package version.
Within version 1, additions are backward compatible; removing a field, changing
a field's meaning or changing the error taxonomy requires a new version and a
`CHANGELOG` migration entry. The application schema (`glaze-schema.json`) is a
separate release contract checked by `raco glaze schema check`.

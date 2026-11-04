# Runtime limits

Glaze bounds the inputs and outputs that a page, a route handler or a plugin
can force the process to buffer. The table records the **current defaults** and
where each one can be changed. Defaults are implementation limits, not
compatibility promises; a value that must be stable belongs in the
application's own contract.

## Bridge and HTTP

| Limit | Default | Change |
| --- | --- | --- |
| HTTP request body | 8 MiB, larger answers `413` | `start-server` / `run-app` `#:max-body-size` |
| Invoke timeout | **none** — a request waits until the handler returns | Client `timeoutMs` / envelope `timeout_ms`; the caller then receives `timed-out` |
| SSE keepalive | 15 s | Framework constant (`glaze/server.rkt`) |
| Event backlog per subscriber | 256 queued batches | `glaze/events.rkt` constants; drops are counted and reported every 5 s |
| Static file containment | Encoded `..` and symlink escape are refused | Framework policy, not configurable |

The native carrier has no HTTP listener and therefore no body-size middleware;
it trusts the WebView message handler as the transport boundary. Both carriers
enforce the same typed envelope rules (see [protocol](protocol.md)); a client
that sends an oversized JSON message to the native carrier is bounded only by
the WebView's own message limits, so application arguments still need their own
validation.

## Outbound HTTP client

`http-request` (and the capability-gated route built on it) defaults to:

| Limit | Default |
| --- | --- |
| Request body | 10 MiB |
| Response body | 10 MiB |
| Total timeout | 30 s |
| Redirects | 5 |

Every request re-checks the redirect target against the `http:request` URL
scope before connecting, and does not forward credential headers across
origins.

## Updates

| Limit | Default |
| --- | --- |
| Manifest fetch | 1 MiB (`fetch-update-manifest #:maximum-bytes`) |
| Manifest redirects | 10, HTTPS-only |
| Artifact download | `updater-config-maximum-download-bytes`, required per application |
| Artifact size | Must equal the signed `size`; checked before hashing |
| Artifact digest | SHA-256 must equal the signed value |
| Signature | Ed25519 over the artifact when the manifest carries one |

## Shell and processes

| Limit | Default |
| --- | --- |
| Command timeout | 30 s |
| Captured stdout | 1 MiB per stream |
| Captured stderr | 1 MiB per stream |
| Managed background processes | 32 |

Output beyond the cap is truncated (and the capture records that it was
truncated); the command is not silently restarted. Program and argument scopes
are checked before spawn; a system shell is never used to join arguments.

## SQLite

| Limit | Default |
| --- | --- |
| Open connections | 16 |
| Rows per result | 10,000 |
| Cell size | 10 MiB |
| Query text | 1 MiB |
| Parameters | 10,000 |

`select`-scoped connections cannot execute write statements; values are bound,
never interpolated.

## Logging

| Limit | Default |
| --- | --- |
| Message length | 8 KiB, truncated |
| In-memory history | 1,000 records |
| File sink rotation threshold | 1 MiB |
| History page request | 1–1,000 records |

## Store, filesystem and paths

| Area | Limit |
| --- | --- |
| Store auto-save | 100 ms debounce; writes are atomic |
| Store size | No framework cap; the whole store is a JSON value in memory |
| `fs-read-text` / `fs-read-bytes` | No per-call cap; the whole file is loaded |
| `fs-write-*` over HTTP | Bounded by the 8 MiB request body; Racket calls are not |
| Path resolver | Rejects absolute escapes, `..` and existing symlink escapes; app ids are sanitized |

If an application accepts large files, enforce its own byte limit before
reading or writing; the framework limit applies to the HTTP envelope, not to a
direct Racket call.

## Fuzzing budgets

The GLZ1 fuzz suite runs a fixed corpus per `raco test`: 5,000 random JSON
values and 1,000 hostile atoms for the envelope decoder, 5,000 and 500 for the
result validator; see `glaze-test/fuzz-test.rkt`.

## Diagnosing a limit

A `413` is the request-body limit; `timed-out` is an invoke timeout the client
set (there is no default); a truncated shell result reports the cap; a dropped
event batch is visible in `bus-dropped-count`. Run `raco glaze doctor --json`
and `raco glaze inspect --json` for the environment and project side of a
failure.

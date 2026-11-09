# GLZ1 fuzzing

Glaze fuzzes the two decoders a hostile page can reach without opening a
window: the GLZ1 invoke-envelope parser and the typed result validator. The
suite is deterministic and runs as part of the normal test run.

## Scope

| Target | Owner | Why it is exposed |
| --- | --- | --- |
| `parse-invoke-envelope` | `glaze/bridge.rkt` | Envelope JSON arrives from the WebView message handler (native transport) or the HTTP adapter |
| `validate-jsexpr` | `glaze/types.rkt` | Racket results cross into JavaScript; validation decides what is structurally acceptable |

The invariant under fuzz is stronger than “does not crash”: every input must
produce either a well-formed decoded value or a typed
`exn:fail:glaze:bridge?` with a stable code. Any other exception, hang or
success with a malformed value is a failure. For the validator, the fuzz oracle
also requires that its verdict agrees with the plain Racket predicate on
acceptance, and that a rejection always carries a string reason.

## Inputs

`glaze-test/fuzz-test.rkt` owns the generators and their exact counts: a
fixed-seed xorshift corpus of random JSON values and hostile atoms (NaN and
infinity, out-of-range integers, 4 KiB strings, invalid methods), plus
known-bad envelopes that pin each error code. This page does not restate the
counts, so changing the corpus does not create a second source of truth.

## Running

```bash
raco test glaze-test/fuzz-test.rkt   # focused
raco test glaze-test/                # the same cases as part of the full suite
```

CI runs the full suite on Windows, macOS and Linux with Racket 9.0 and 9.3.
There is no separate fuzz job because these cases are already in the main test
run; adding a second workflow would re-execute the same seeded corpus.

## Extending it

When the protocol or typed-contract vocabulary changes:

1. add the new shape to the generator (not only a single hand-written case);
2. state the invariant — accepted value or a specific typed error code;
3. add known-bad cases for every new rejection path;
4. keep the seed fixed and the iteration count bounded so the suite stays
   usable on CI.

Do not relax the invariant to “no exception”. A decoder that accepts malformed
input, or throws an untyped error, is a defect even when the process survives.

## Limits

- Deterministic generation is reproducible but not coverage-guided; it does not
  replace review of the decoder's state machine.
- The suite does not fuzz native frame parsing, HTTP header parsing, WebView
  IPC, or concurrent stream shutdown. Those are exercised by the bridge,
  native-delivery, HTTP-security and soak suites instead.
- A green fuzz run is not a security audit. See [SECURITY.md](../SECURITY.md)
  for the trust model and reporting route.

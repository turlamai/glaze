# Glaze documentation map

This directory has one owner for each durable decision. New documents must link from this map and must not create a second source of truth for an existing subject.

## Architecture and governance

- [Current architecture](architecture.md): the runtime, transport, trust, module, and dependency boundaries that are true today.
- [Glaze 1.0 plan](1.0-plan.md): the active sequence, gates, evidence, work ownership, and next implementation handoff. Delete it after the 1.0 gates close.
- [API stability](api-stability.md): public-module tiers, compatibility rules, and the exact export gate.
- [AI implementation handoff](agent-handoff.md): the one-slice execution, ownership, validation, and stop rules used by ZCode and other agents.

## Developer and product contracts

- [Getting started](getting-started.md) / [简体中文](getting-started.zh-CN.md): canonical install, scaffold, typed route, schema, native verification, and build tutorial.
- [Agent-native workflow](agent-native.md): project inspection, diagnosis, editing, and native-window verification.
- [GUI-first contract](gui-first.md): why application startup requires a native WebView and never falls back to a browser tab.
- [CI contract](ci.md) / [简体中文](ci.zh-CN.md): the minimum gates an application must prove on each platform, runner requirements, and the evidence to record.
- [Diagnostics](diagnostics.md): symptom-to-cause troubleshooting for startup, schema, verification, packaging and update failures.
- [Product acceptance](product-acceptance.md): the scenario record and evidence levels that define when a packaged application is done.
- [Production signing](production-signing.md): trust domains, certificate and notary prerequisites, key handling in CI, and the verification checklist.
- [Releasing and updating applications](release-and-updates.md): release identity, update channels, staged rollout, signed manifests, rollback and the N→N+1 evidence per installation shape.
- [GLZ1 fuzzing](fuzzing.md): the decoders under fuzz, the invariant, the seeded inputs and how to extend the corpus.
- GLZ1 wire contract: the normative section in the [API manual](../glaze-doc/scribblings/glaze.scrbl); this map does not keep a second copy.
- [Runtime limits](runtime-limits.md): request-body, timeout, redirect, output, row, history and process defaults, and where each can be changed.
- [Releasing](RELEASING.md): framework release procedure and provenance requirements.
- [Performance baseline](benchmarks.md): what the framework measures, the recorded baseline, and the honesty rules for comparing results.

The generated HTML site under `docs/index.html` is product-facing material. The Racket API reference lives under `glaze-doc/scribblings/`. Durable engineering decisions belong in the Markdown owners above, then user-facing material should link to or summarize them.

## Adoption and support

[English guide](USING.md) · [简体中文](USING.zh-CN.md): fit, maturity, upgrade boundaries and support. This user path links to the existing canonical technical owners above.

[Security policy](../SECURITY.md): private vulnerability reporting, supported versions and the framework trust model.

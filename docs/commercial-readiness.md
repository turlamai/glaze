# Commercial readiness and Rivet migration qualification

This is a release gate, not a declaration of certification. See [product acceptance](product-acceptance.md), [release and updates](release-and-updates.md), [production signing](production-signing.md) and [API stability](api-stability.md).

## Baseline (2026-11-25)

Glaze v0.19.0 publishes Windows x64 MSI, macOS arm64 DMG, Linux amd64 DEB, x86_64 RPM/AppImage, source ZIP and SHA256SUMS. Other architecture or installer support must be demonstrated separately. The published asset inventory does not yet include the SBOM/notices that current main's release workflow generates. Verify these against the next actual tag, not just workflow source.

Open defects at baseline: #169 native/HTTP permission parity, #172 CSP and third-party content, #165 Linux capture/SSE, #173 Windows console/icon (PR #174), #171 scoped keep-awake. Recheck their state before release; security defects require regression tests and explicit disposition.

## Downstream inventory

Repository trees on main show Glaze configuration in taskly, booklight, podlens, relaypilot, layerly and termpilot. Some also retain Rivet configuration; presence does not establish which runtime ships. gptp-studio has a Glaze validation document but Rivet configuration; autarx, fulcrum, movebit, syncpilot, flashpilot and threadly retain Rivet configuration. Publy and postly require separate inspection before classification. This is a sampled inventory, not an exhaustive dependency graph.

For each consumer record repository, commit, runtime actually selected by release workflow, pinned framework version, supported OS/architecture, installer identity, last shipped version and evidence links. Do not delete legacy files until release and upgrade paths no longer depend on them. Private consumers should run the same contract in their own CI without granting public PRs access to secrets.

## Release gates

| Gate | Required evidence |
| --- | --- |
| Runtime | Native window renders and responds; permission parity for HTTP/native; CSP policy tested against local and remote content; capture and streaming coexist |
| Identity | Stable product ID, publisher, data directory and upgrade identity across Rivet to Glaze; explicitly document any mapping |
| Icons | One product-owned source; validate ICO/ICNS/PNG assets and high-DPI variants; inspect executable, window/taskbar/Dock, installer, installed-apps entry, launcher and tray where applicable; missing/invalid assets fail or produce an explicit diagnostic |
| Packaging | Exact release artifacts install on clean supported OS/architecture without developer runtime; launch and uninstall; no orphan shortcuts, duplicate entries or unexpected console; user data preserved by default |
| Updates | Real signed manifest and artifact, N to N+1, interrupted download, wrong key/digest, install failure, restart failure and supported rollback; package-manager ownership respected |
| Migration | Install the actual last Rivet artifact, create representative data, upgrade to Glaze, verify one installation, retained data/settings and working launch; test uninstall/reinstall |
| Trust | Platform signature/notarization verified when required, pinned updater key, checksums covering assets, SBOM and notices attached, no secrets in logs |
| Documentation | Fresh-project tutorial, API reference, migration guide, packaging/signing/update examples and troubleshooting match shipped CLI; commands exercised in CI |
| Accessibility | Keyboard, IME, scaling, focus, screen-reader names and OS-specific behavior exercised |
| Performance | Startup, idle CPU/memory, artifact size and shutdown measured against recorded per-platform baseline |
| Compatibility | Candidate Glaze tested by each supported downstream against its pinned baseline; product-specific scenarios and package smoke, not just framework tests |

For each gate use PASS, FAIL, NOT RUN or NOT APPLICABLE (with reason), exact commit and artifact SHA-256, OS/architecture, test/run URL, and owner. Missing evidence is not PASS.

## Integration policy

The existing family compatibility workflow tests Keel on Linux, not downstream product releases. Add an opt-in candidate-testing workflow in each product or a controlled dispatcher using immutable Glaze revisions. Run core tests and native verification on pull requests; run installation and upgrade qualification on release candidates. Do not execute arbitrary downstream code with release credentials. Maintain a consumer matrix and block supported release claims when required evidence is missing.

Glaze owns reusable mechanics and diagnostics; products own branding, business workflows, user-data migration, licensing policies and signing identities. Avoid copying framework fixes into every consumer. Do not publish a new tag solely to close this audit.

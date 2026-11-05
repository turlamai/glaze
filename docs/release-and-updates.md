# Releasing and updating a Glaze application

This page owns the product-side release and update policy: identity, channels,
staged rollout, rollback and the evidence an update must carry. Framework
releases are [RELEASING.md](RELEASING.md); the exact update API is in the
Scribble manual (`raco docs glaze`) and summarized in the
[README update section](../README.md#update-integrity). Code signing is
[production signing](production-signing.md).

## Release identity

- Keep `--identifier` stable for the life of the product. Glaze derives the
  MSI `UpgradeCode` and NSIS uninstall identity from it; a change makes the new
  installer a different product.
- Increase `--version` monotonically. The `ProductCode` rotates per version, and
  clients compare SemVer, not build numbers.
- Keep `application_id` in the update manifest equal to the installed
  application's identity; `select-update` rejects a manifest for another app.
- Publish the artifact digest with the release. The update manifest repeats
  the SHA-256 and exact byte size, and the client refuses a mismatch.

## What a release contains

| Artifact | Purpose | Notes |
| --- | --- | --- |
| `.zip` / `.tar.gz` | Portable fallback | Produced when an installer toolchain is absent; replace-atomic install plan fits this shape |
| `.msi` | Windows install/upgrade | WiX; stable `UpgradeCode`, rotating `ProductCode` |
| `.dmg` | macOS drag-install | Apple Silicon by default in Glaze's own matrix; do not claim Intel without building it |
| `.deb` / `.rpm` / `.AppImage` | Linux | One FHS payload feeds all three; the package manager owns install/upgrade for deb/rpm |
| Signed update manifest | Update discovery | Separate from OS signing; see below |

Glaze's own release publishes a source ZIP plus showcase installers. An
application should publish its own artifacts and never point users at the
framework's showcase installers.

## Update channels

Glaze recognizes three channels, and the manifest is validated against its own
channel before it is signed or accepted:

| Channel | Accepts |
| --- | --- |
| `stable` | Versions without a prerelease component |
| `beta` | Stable versions and prereleases whose identifiers start with `beta` |
| `dev` | Any valid SemVer |

`select-update` requires the client channel and manifest channel to be equal;
it does not silently promote a beta client to stable. Decide the channel per
installation and keep it in the updater config.

## Staged rollout

The manifest carries `rollout` from 0 through 100 and a `minimum_version`.
`select-update` returns a candidate only when:

- the application id matches;
- the manifest version is newer than the installed version;
- the installed version is at or above `minimum_version`;
- the client's `rollout-bucket` is below `rollout`;
- an artifact matches the client platform and architecture.

A `rollout` of 0 pauses the release; 100 offers it to everyone. Keep the
bucket stable per installation (hash the installation id) so a user does not
flap in and out of an update. If the current version is below
`minimum_version`, publish an intermediate release instead of skipping the
upgrade path.

## Signed manifests

The wrapper is schema 1: a base64 payload plus an Ed25519 `signature` with a
`key_id`. The payload binds the application id, version and build, channel,
publish time, minimum/previous version, rollback permission, rollout and the
artifact list. The field-by-field schema lives in the manual (`glaze/update`);
this page does not duplicate it.

Operational rules:

- Fetch manifests over HTTPS only; redirects must stay HTTPS and are capped.
  The default manifest read limit is 1 MiB.
- Set `expected-key-id` (the `#:key-id` argument) so a manifest signed by a
  different key is rejected even when that key is valid.
- Verify the artifact's size, SHA-256 and, when present, its Ed25519
  signature before install. `verify-file-sha256` returning `#f` covers both
  “mismatch” and “could not check”; neither is success.
- Keep update keys separate from OS signing certificates and from Permit
  issuer keys.

Key rotation: publish the new public key in the application before signing
manifests with it, keep the old key trusted for one release, and use distinct
`key_id` values so a client can tell them apart.

## Install and rollback

Use `make-replace-install-plan` for portable artifacts: it stages a file or a
whole directory (a macOS `.app` is a directory), moves the previous target to
the rollback backup, then renames the staged copy into place. A failure before
that swap leaves the installed target untouched; a restart failure restores the
backup when the manifest allows rollback. For MSI/EXE/PKG/DMG, use
`make-install-plan` with an adapter that owns elevation and process handoff;
Glaze still verifies the input and invokes the rollback procedure when
installation fails.

Rollback is invoked only when the manifest sets `rollback_allowed: true` and
the install or restart step raises. Test that path deliberately: a release
whose rollback would delete user data is worse than a failed install. The
application owns data migration, backup and restore; Glaze does not touch the
product's data.

## Evidence for each installation shape

For every supported installation shape (portable zip, MSI, dmg, deb, rpm,
AppImage), record an N→N+1 run:

1. install version N from the published artifact;
2. start it and complete the first-run scenario;
3. check, download and install N+1 through the real manifest;
4. confirm version N+1 starts, data survived and the app reports the new
   version;
5. inject a bad signature or digest and confirm the update is rejected;
6. force an install failure and confirm rollback when allowed.

A green unit suite or a surviving process does not prove an update. Record the
artifact digests, the manifest key id, the platform and the run URL.

## What CI proves today

The package job builds the installer on each hosted platform and then exercises
the installation shape instead of only inspecting the archive:

| Shape | CI evidence |
| --- | --- |
| Windows MSI | silent install of N, payload and one uninstall entry, upgrade to N+1 with a rotated ProductCode and new DisplayVersion, uninstall by ProductCode, directory and registry entry gone |
| macOS dmg | mount, `.app` plus `/Applications` symlink, drag-style copy, bundle version and executable checked |
| Linux deb | dpkg install, launcher/library/desktop entry, upgrade to N+1 through dpkg, remove |
| Linux rpm | dnf install, version query, upgrade to N+1, erase inside a Fedora container |
| AppImage | `--appimage-extract-and-run` under Xvfb survives the launch window (early crash fails) |
| Portable update | manifest selection, artifact size/SHA-256, same-size corruption rejection, directory replacement, rollback and failed-restart restore (`update-install-flow-test.rkt`); live HTTPS manifest fetch and download against a local CA when OpenSSL 3 is available (`update-download-flow-test.rkt`) |

This is installation-shape evidence, not a claim that every release is signed:
the tag workflow currently builds unsigned showcase installers. The live
HTTPS path is covered by a local-CA test only on hosts with OpenSSL 3, not by
the package job. Installer signing/notarization and a production manifest host
remain release-credential work, recorded here rather than implied by a green
package job.

## Don'ts

- Do not publish a manifest before its artifacts; a client that selects a
  candidate must be able to download it.
- Do not reuse `--identifier` for a fork or a different product.
- Do not silently switch an installed product to a different update channel.
- Do not treat a missing certificate, absent installer toolchain or unsigned
  artifact as a successful release.
- Do not let a failed update delete the only backup of user data.

# Production signing and notarization

This page owns the operational side of shipping a signed Glaze application:
which identity signs what, how to keep keys out of the repository, and how to
verify the result. The `build` flags themselves are listed in the
[README](../README.md#code-signing--notarization); the update-signing keypair
is a separate mechanism documented under [update integrity](../README.md#update-integrity).

## Separate trust domains

Do not reuse one key for several jobs:

| Purpose | Owner | Mechanism |
| --- | --- | --- |
| macOS app identity | Application publisher | Developer ID Application certificate + `codesign` |
| Windows app identity | Application publisher | Authenticode certificate + `signtool` |
| Linux packages | Distribution channel | Repository signing / checksums chosen by the product; Glaze does not sign deb/rpm/AppImage |
| Update manifests and artifacts | Application publisher | Pinned Ed25519 key (`raco glaze updater-keygen`), separate from OS identities |
| Commercial entitlements | [Permit](https://github.com/turlamai/permit) | Permit issuer keys, never loaded by the desktop verifier |

Glaze signs code and verifies updates; it does not issue certificates, hold
notary credentials, rotate keys for you, or provide a signing service.

## macOS

Prerequisites:

- a **Developer ID Application** certificate in the login keychain (an Apple
  Development certificate is not accepted by Gatekeeper for distribution);
- Xcode command-line tools (`codesign`, `xcrun`, `stapler`);
- a notarytool keychain profile created once per machine or CI account:

```bash
xcrun notarytool store-credentials acme-notary \
  --apple-id "release@example.com" --team-id TEAMID --password "app-specific-password"
```

Build:

```bash
raco glaze build --name myapp --version 1.2.3 \
  --sign "Developer ID Application: Example Inc (TEAMID)" \
  --notarize acme-notary --installer
```

Hardened runtime is applied automatically and is required for notarization.
Pass `--entitlements <plist>` for the capabilities the app actually needs; do
not add blanket entitlements to make notarization pass. `--notarize` submits
the built dmg with `notarytool`, waits for the result and staples the ticket.
Signing failures abort the build. Ad-hoc signing (`--sign -`) is for local
testing and CI smoke only; it suppresses hardened runtime because library
validation would reject the app's own framework.

Verify:

```bash
codesign --verify --strict --verbose=2 myapp.app
codesign -dv --verbose=4 myapp.app
spctl -a -vv -t exec myapp.app
xcrun stapler validate myapp.dmg
```

A successful `codesign --verify` proves the signature is internally consistent;
`spctl` and the stapler check are what Gatekeeper actually evaluates.

## Windows

Prerequisites:

- an Authenticode code-signing certificate (OV or EV) with its private key in a
  certificate store or a password-protected PFX available to the runner;
- the Windows SDK `signtool`;
- network access to an RFC-3161 timestamp authority.

Build:

```bash
raco glaze build --name myapp --version 1.2.3 \
  --sign 40HEXCHARS --installer
```

`--sign` accepts a SHA-1 thumbprint or a certificate subject. Glaze timestamps
with `--timestamp-url` (an RFC-3161 server) and signs the installer artifact as
well as the application. Keep `--identifier` stable across releases; it derives
the MSI `UpgradeCode`, while the `ProductCode` rotates per version.

Verify:

```powershell
signtool verify /pa /all myapp.exe
signtool verify /pa /all myapp.msi
```

SmartScreen reputation is not granted by a valid signature alone; a new
certificate accumulates reputation over downloads. Do not describe an unsigned
or ad-hoc build as release-signed.

## Linux

Glaze produces deb, rpm and AppImage payloads from one FHS staging tree, but it
does not add an OS-level signature to them. If the product distributes through
a package repository, sign the repository metadata and publish checksums with
the product's own release process. An AppImage is an archive, not a signed
bundle; state the verification method the product actually provides.

## CI key handling

- Store certificates, PFX files, passwords and notary credentials in the CI
  secret store, never in the repository or build logs.
- Import a macOS `.p12` into a temporary keychain in the signing job and delete
  the keychain afterwards; scope the job to the release branch.
- Give the signing job the minimum permissions it needs; do not expose update
  keys to the same job unless the release process requires it.
- Rotate on a schedule and after any suspected exposure. Publish the new update
  public key before signing manifests with it, so installed clients can verify
  the rotation.
- Treat a missing certificate as a failed release, not as an unsigned success.
  Glaze warns and degrades when a *toolchain* is absent; that warning must not
  be ignored for a published artifact.

## Verification checklist

- [ ] the artifact was built from the tagged commit, not a dirty checkout;
- [ ] macOS: `codesign --verify --strict`, `spctl`, `stapler validate` pass;
- [ ] Windows: `signtool verify /pa /all` passes for the app and the installer;
- [ ] the installer identity (`--identifier`) matches the previous release;
- [ ] the artifact SHA-256 matches the release notes and update manifest;
- [ ] the update manifest is signed by the pinned key id, not a development key;
- [ ] a clean machine can install, launch and complete the first-run scenario.

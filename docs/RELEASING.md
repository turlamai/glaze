# Releasing Glaze

Glaze uses two equivalent version forms: `info.rkt` carries the canonical
Racket package version (for example `0.7`), while `release-version`, Git tags,
the changelog, and GitHub Releases use three-component SemVer (`0.7.0`).

1. Move the pending changelog entries into a dated release section.
2. Update both version bindings and the README release badges.
3. Merge the fully green release-preparation pull request into `main`.
4. Create and push an annotated `vMAJOR.MINOR.PATCH` tag on that exact commit.

Before tagging, run `raco glaze check-release-version vMAJOR.MINOR.PATCH`
(add `--allow-rc` for a `vMAJOR.MINOR.PATCH-rc.N` candidate) to preflight the
alignment locally: the two `info.rkt` version forms must agree, `CHANGELOG.md`
must carry the release, and the tag must match. The same command runs as a
pre-merge CI gate and again in the tag workflow, so drift is caught before a
release exists. Pass `--carrier FILE` to require additional version-bearing
files, and `--json` for a machine-readable report.

Applications built with Glaze that publish a signed update feed should also
gate the real assets before publishing them. After building the installers
and signing the update manifest, run
`raco glaze verify-release-assets <manifest.json> <release-dir> <public.pem>
--base-url https://github.com/<owner>/<repo>/releases/download/v<version>
--key-id <id> --require <platform:arch:installer>... --json`. This offline
gate authenticates the manifest, pins the GitHub base URL to the immutable
release tag (never `latest`), and checks that every signed asset exists as a
regular file with the signed size and SHA-256, that its filename matches the
installer kind, and that every required target is present. It needs no
network access or private key and fails closed (exit 1) on any divergence, so
a missing, renamed, or mutated installer cannot reach the feed.

The tag workflow verifies that the commit belongs to `main`, runs the complete
package test suite, builds the Scribble manual, creates the Racket source ZIP,
installs that exact ZIP into a fresh package scope, and publishes the archive,
checksum, and changelog notes as a GitHub Release.

The release has two surfaces: `glaze-<version>.zip` is the installable Racket
source package; `glaze-<version>-<platform>-<architecture>.<extension>` files
are **showcase application installers**, not separate distributions of the
framework. Currently these are Windows x64 MSI, macOS arm64 DMG, Linux amd64
DEB and Linux x86_64 RPM/AppImage. We do not imply an Intel macOS binary or
other architectures that the matrix does not actually build.

Every published binary is version-pinned. The single `SHA256SUMS` lists the
hashes of all six published downloads; per-file checksum sidecars stay in
build artifacts and are verified before promotion. Do not publish debugging
outputs, duplicate versionless installers, or a showcase updater manifest as
part of the framework's GitHub Release. GitHub-generated source archives are
separate from the installer matrix.

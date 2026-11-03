# Releasing Glaze

Glaze uses two equivalent version forms: `info.rkt` carries the canonical
Racket package version (for example `0.7`), while `release-version`, Git tags,
the changelog, and GitHub Releases use three-component SemVer (`0.7.0`).

1. Move the pending changelog entries into a dated release section.
2. Update both version bindings and the README release badges.
3. Merge the fully green release-preparation pull request into `main`.
4. Create and push an annotated `vMAJOR.MINOR.PATCH` tag on that exact commit.

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

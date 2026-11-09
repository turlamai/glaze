# Shipping a Glaze application through CI

This page owns the **consumer** CI contract: what an application built with
Glaze should prove before it ships. Glaze's own pipeline lives in
`.github/workflows/ci.yml`; an application should not copy that file or its
internal jobs.

## Evidence rule

A platform gate is satisfied only by a run on that platform. A unit suite, a
screenshot taken in development, or a successful `--help` invocation does not
replace opening the real window or launching the packaged artifact. Skipped,
cancelled and unrun jobs are not passes.

## Minimum gates

| Gate | Command | Fails when |
| --- | --- | --- |
| Environment | `raco glaze doctor --json` | `usable` is false or the exit code is nonzero: package ownership, collection resolution or WebView readiness is broken |
| Schema contract | `raco glaze schema check --json` | a protocol, route, command, named-type, error or ordering break against the committed `glaze-schema.json` |
| Native acceptance | `raco glaze verify` | the real system WebView never loads, the URL differs, or screenshot capture fails |
| Packaged launch | `raco glaze measure startup --seconds 3` | the packaged artifact exits inside the survival window |
| Size budget | `raco glaze measure size --budget budgets.json` | an artifact exceeds its first matching glob budget |
| Installer shape | `raco glaze build --installer ...` plus platform validation | the toolchain was silently absent, MSI upgrade identity changed, or expected package contents are missing |
| Updates | the application's own N→N+1 scenario | a signature or hash is rejected incorrectly, or install/rollback is not exercised |

Run these from the application project root, after installing Glaze and the
application's own dependencies:

```bash
raco glaze doctor --json
raco glaze schema check --json
raco glaze verify
raco glaze build --name myapp --version 1.2.3 --publisher "Example Inc" \
  --identifier com.example.myapp --installer --sign -
raco glaze measure startup --seconds 3
raco glaze measure size --budget budgets.json
```

`doctor`, `schema check` and `measure` exit nonzero on failure; `verify` exits
with the project verifier's status. The generated `verify.rkt` checks title,
URL and PNG capture; extend it with the application's first-run route and
persistence assertions (see [product acceptance](product-acceptance.md)).

A size budget is a committed JSON file; the first matching glob wins, so list
the most specific artifact first:

```json
{"rules": [{"glob": "*.dmg", "max-bytes": 400000000},
           {"glob": "*", "max-bytes": 500000000}]}
```

## Runner requirements

| Platform | Requirements | Unattended notes |
| --- | --- | --- |
| macOS | A logged-in graphical session; Xcode command-line tools for `codesign`; a `notarytool` keychain profile for notarization | Hosted macOS runners can open WKWebView windows; an SSH-only host cannot |
| Windows | WebView2 Runtime (preinstalled on hosted runners); WiX for MSI (`dotnet tool install --global wix --version 5.0.2`); `signtool` plus a certificate for signed releases | Unsigned or ad-hoc builds must not be published as release artifacts |
| Linux | GTK 3 and WebKitGTK 4.1 development packages, `xvfb`, `dpkg`, `rpm`, AppImage tooling | Run windowed commands under `xvfb-run -a`; set `WEBKIT_DISABLE_DMABUF_RENDERER=1` on GPU-less runners |

ARM64: Apple Silicon, Linux ARM64 and Windows ARM64 use native Racket builds.
Glaze ships both `win-x64` and `win-arm64` `WebView2Loader.dll` and selects by
the process architecture; the x64 build also runs under emulation on ARM64
hosts. The hosted Intel macOS runner is build-only (no WindowServer session);
real-window Intel evidence needs a desktop or self-hosted runner.

Set `GLAZE_NO_STARTUP_DIALOG=1` in unattended jobs so a failed WebView startup
reports an error instead of waiting on an OS dialog. The dialog is for
interactive desktops; suppressing it does not suppress the failure.

## Example job

This is a starting point, not a release pipeline: signing, notarization and
installer publication need repository secrets and a release-only job.

```yaml
name: app-ci
on: [push, pull_request]
jobs:
  verify:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-24.04, windows-latest, macOS-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v7
      - uses: Bogdanp/setup-racket@v1.15
        with:
          version: '9.3'
      - name: Install application
        shell: bash
        run: raco pkg install --auto --no-docs --link .
      - name: Compile and test
        shell: bash
        run: |
          raco make main.rkt
          # raco test test/   # your application suite, when one exists
      - run: raco glaze schema check --json
      - run: raco glaze doctor --json
      - name: Native acceptance
        env:
          WEBKIT_DISABLE_DMABUF_RENDERER: '1'
          GLAZE_NO_STARTUP_DIALOG: '1'
        shell: bash
        run: |
          if [ "$RUNNER_OS" = "Linux" ]; then
            xvfb-run -a raco glaze verify
          else
            raco glaze verify
          fi
```

Pin actions by commit SHA in a real repository, as Glaze's own workflows do.
Build, installer and signing steps belong on the release branch with secrets
scoped to that job.

## What not to gate on

A unit suite, a `doctor` run, or a screenshot alone is not a gate: they prove
logic, environment, or a single frame respectively. [Product acceptance](product-acceptance.md)
owns the evidence levels; this page owns the commands that produce them.

## Evidence to record

For each platform, record:

- repository SHA, the Glaze version (and `keel` version) actually installed,
  and the Racket version;
- OS and architecture;
- artifact name and SHA-256;
- the scenario and the exact command;
- the run URL or log.

Keep `glaze-schema.json` and `verify.rkt` in review like application code.
Updating the schema baseline to make a red check green hides a contract break;
it is a deliberate, reviewed change.

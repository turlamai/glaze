# Security Policy

Glaze is pre-1.0 and has not undergone an independent security audit. This
policy covers the framework repository. Shipped products remain responsible for
their own threat model, OS signing identity, update keys and user data.

## Reporting a vulnerability

Do not publish a suspected vulnerability in a public issue. Use GitHub's private
vulnerability reporting for this repository (**Security** → **Report a
vulnerability**), or contact the repository owner privately when that route is
unavailable.

Include the affected version or commit, platform and Racket version, the command
or route involved, and a minimal reproduction. Do not attach real signing keys,
publisher certificates, customer data or private documents. We will confirm
receipt, investigate, and coordinate a disclosure date with you before any
public write-up.

## Supported versions

Fixes land on `main` and the latest published 0.x release. Older 0.x minors do
not receive security backports. Applications should pin a version and record the
platforms they actually test.

## Trust model

- The Racket backend is **trusted application code**. It runs with the user's OS
  permissions; Glaze is not a sandbox between the backend and the operating
  system, and a compromised backend is not contained by the framework.
- The frontend (HTML/CSS/JS in the WebView) is **untrusted relative to the
  backend**. It can reach only declared API routes and the services the
  application enables.
- The OS user account is the isolation boundary between one application and
  another.
- The HTTP adapter binds loopback only and requires an API token plus the
  Origin/`Sec-Fetch-Site` request guard. The native GLZ1 transport carries no
  token because the WebView message handler is the trust boundary; capability
  checks still apply.
- Capability enforcement is opt-in with `run-app #:capability`. Without it, every
  declared route is callable by the page. Applications that render untrusted
  content, load remote resources, or expose filesystem/shell/HTTP access should
  enable it: authority then becomes default-deny and each permission carries a
  path, command, host or argument scope.
- Update-signing keys, OS code-signing identities and
  [Permit](https://github.com/turlamai/permit) credential keys are separate trust
  domains. Do not reuse one key across them.

## Security-sensitive areas

Treat changes to these owners as security review items:

- GLZ1 envelope decoding, typed result validation and bridge dispatch
  (`glaze/bridge.rkt`, `glaze/types.rkt`, `glaze/private/bridge-dispatch.rkt`,
  `glaze/private/native-delivery.rkt`);
- capability authority and scope checks for filesystem paths, shell commands,
  HTTP hosts, SQL and system plugins (`glaze/capability.rkt`,
  `glaze/private/http-security.rkt`);
- static-resource containment, including encoded traversal and symlink escape
  (`glaze/server.rkt`, `glaze/assets.rkt`);
- native transport bootstrap, scheme-handler responses and generated client
  escaping (`glaze/native-transport.rkt`, `glaze/private/native-client.rkt`);
- update and manifest signature verification, archive extraction and staged-file
  handling (`glaze/update.rkt`, `glaze/private/ed25519-public.rkt`,
  `glaze/private/archive-fallback.rkt`);
- installer metadata and upgrade identity (`glaze/private/windows-installer*`,
  `glaze/private/macos-bundle*`, `glaze/private/linux-package*`);
- native FFI loading boundaries for WebView2, WKWebView and WebKitGTK, including
  `WebView2Loader.dll` staging.

The framework suite exercises these boundaries in `glaze-test/security-test.rkt`,
`glaze-test/http-security-test.rkt`, `glaze-test/capability-test.rkt`,
`glaze-test/hardening-test.rkt` and `glaze-test/fuzz-test.rkt`.

## Hardening checks

Before shipping an application, run the generated acceptance script and the
framework diagnostics in the application project:

```bash
raco glaze doctor --json
raco glaze schema check --json
raco glaze verify
```

`verify` opens the real native window and checks the application's declared
first-run acceptance scenario; `doctor` reports missing WebView and packaging
dependencies. Neither replaces a product-specific threat model or packaged
release test.

## Scope

In scope: framework code in this repository and the documented trust boundaries
above.

Out of scope: vulnerabilities in an application's own routes, HTML/JS, data
handling or key management; defects in operating-system WebView components,
WebView2 Runtime, GTK/WebKitGTK or third-party Racket packages. Report those to
the owning project or vendor.

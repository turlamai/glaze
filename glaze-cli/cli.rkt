#lang racket/base

(require racket/list
         racket/match
         glaze-cli/pkg
         glaze-cli/inspect
         glaze-cli/private/acceptance
         glaze-cli/private/build-command
         glaze-cli/private/compliance
         glaze-cli/private/init
         glaze-cli/private/matrix
         glaze-cli/private/measure
         glaze-cli/private/release-assets
         glaze-cli/private/release-version
         glaze-cli/private/run
         glaze-cli/private/schema
         glaze-cli/private/support-bundle
         glaze-cli/private/update-command)

(define (print-help)
  (displayln "Usage: raco glaze <command> [args]")
  (displayln "")
  (displayln "Commands:")
  (displayln "  init <name>   Create a native Glaze desktop project")
  (displayln "  dev           Run this project's native Glaze desktop app")
  (displayln "  build         Build a distributable (raco exe + raco distribute)")
  (displayln "  updater-keygen  Create an Ed25519 keypair for update signing")
  (displayln "  update-sign   Sign an update artifact (Ed25519 over its sha256)")
  (displayln "  update-verify Verify an update artifact signature")
  (displayln "  manifest-sign Sign a validated update manifest")
  (displayln "  manifest-verify Verify a signed update manifest")
  (displayln "  install       Pin the glaze package to a revision and link it")
  (displayln "  doctor        Diagnose package/WebView readiness (--json for agents)")
  (displayln "  compliance    SBOM, third-party notices, and license audit (--json)")
  (displayln "  support-bundle  Redacted diagnostic ZIP for issue reports (--out FILE)")
  (displayln "  acceptance    Bounded headless acceptance evidence (--json, --out FILE)")
  (displayln "  matrix        Fold per-platform acceptance reports (<report>... --json)")
  (displayln "  inspect       Show project edit/verification map (--json for agents)")
  (displayln "  schema        Write/check the committed application schema contract")
  (displayln "  verify        Run the project native UI verification script")
  (displayln "  measure       Report packaged-app size/startup against budgets")
  (displayln "  check-release-version  Preflight release version alignment (<tag> --allow-rc --json)")
  (displayln
   "  verify-release-assets  Offline gate for signed release assets (<manifest> <dir> <pubkey> --base-url URL --json)")
  (displayln "  help          Show this help")
  (displayln "")
  (displayln "Glaze requires a working native WebView. If it is missing or broken, startup")
  (displayln "fails with platform-specific installation/repair instructions; it never opens")
  (displayln "the system browser as a fallback.")
  (displayln "")
  (displayln "build options:")
  (displayln "  --name <name>        app/bundle name (default: project dir)")
  (displayln "  --version <v>        app version (Info.plist / MSI metadata)")
  (displayln "  --publisher <name>   native installer publisher (default: app name)")
  (displayln "  --identifier <id>    stable installer identity (default: app name)")
  (displayln "  --icon <path>        .ico (Windows) / .icns (macOS)")
  (displayln "  --entry <path>       entry file (default: main.rkt)")
  (displayln "  --out <dir>          output directory (default: dist)")
  (displayln "  --embed-dlls         Windows: embed DLLs into a single .exe")
  (displayln "  --installer          Also build a platform installer (msi/dmg/AppImage);")
  (displayln "                       falls back to zip/tar.gz when the toolchain is absent")
  (displayln "  --sign <id>          Code-sign the app (macOS: codesign identity, \"-\" =")
  (displayln "                       ad-hoc; Windows: signtool cert SHA-1 or subject)")
  (displayln "  --entitlements <p>   macOS: .entitlements plist for codesign")
  (displayln "  --no-hardened-runtime  macOS: skip hardened runtime (notarization needs it)")
  (displayln "  --timestamp-url <u>  Windows: RFC-3161 timestamp server for signtool")
  (displayln "  --notarize <profile> macOS: notarize + staple via notarytool keychain profile")
  (displayln "  --url-scheme <name>  Deep-link URL scheme (repeatable): macOS gets")
  (displayln "                       Info.plist entries; call (ensure-url-scheme! ...)")
  (displayln "                       at app start on Windows/Linux)")
  (displayln "  --dmg-background <p> macOS: branded DMG background .png (1320x800 at")
  (displayln "                       144dpi); switches to the drag-to-install layout")
  (displayln "  --installer-license <p>  Windows: .rtf for the MSI wizard license page")
  (displayln "  --installer-banner <p>   Windows: 493x58 .bmp wizard banner artwork")
  (displayln "  --installer-dialog <p>   Windows: 493x312 .bmp wizard dialog artwork"))

;; Dispatch CLI commands
(define args (vector->list (current-command-line-arguments)))
(cond
  [(null? args) (print-help)]
  [else
   (define cmd (car args))
   (define rest (cdr args))
   (match cmd
     ["init"
      (init-project (if (null? rest)
                        "myapp"
                        (car rest)))]
     ["dev" (dev-app)]
     ["inspect" (exit (run-inspect #:json? (member "--json" rest)))]
     ["schema" (exit (run-schema-command rest))]
     ["verify" (exit (verify-app))]
     ["measure" (measure-command rest)]
     ["build" (build-command rest)]
     ["updater-keygen" (updater-keygen-command rest)]
     ["update-sign" (updater-sign-command rest)]
     ["update-verify" (updater-verify-command rest)]
     ["manifest-sign" (manifest-sign-command rest)]
     ["manifest-verify" (manifest-verify-command rest)]
     ["install" (install-command rest)]
     ["doctor" (doctor-command rest)]
     ["compliance" (exit (compliance-command rest))]
     ["support-bundle"
      (exit (support-bundle-command rest
                                    #:doctor (lambda () (doctor-jsexpr))
                                    #:inspect (lambda ()
                                                (and (file-exists? (build-path (current-directory)
                                                                               "glaze.rktd"))
                                                     (project-report)))))]
     ["acceptance" (exit (acceptance-command rest #:doctor (lambda () (doctor-jsexpr))))]
     ["matrix" (exit (matrix-command rest))]
     ["check-release-version" (exit (release-version-command rest))]
     ["verify-release-assets" (exit (verify-release-assets-command rest))]
     ["help" (print-help)]
     [_
      (printf "Unknown command: ~a\n" cmd)
      (print-help)])])

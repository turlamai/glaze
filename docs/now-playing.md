# OS Now Playing (host-owned)

Glaze publishes the product's playback state to the operating system's Now
Playing surface from the **host process**, not from the web engine's
MediaSession bridge. Products call one API on every platform; the capability
is optional and degrades to an inert stub where no backend exists.

Why host-owned: WebKitGTK's MPRIS bridge never owns a bus name on headless
CI and is unreliable on real desktops (WebKit bug 279362), and macOS's
private MediaRemote interface drifts across releases. A host-owned surface
is deterministic, testable over the bus, and built only on public platform
APIs.

## API

```racket
(require glaze/now-playing) ; also re-exported by glaze/services

(now-playing-supported?)                 ; -> boolean?
(now-playing-set! (hash 'title "Episode"
                        'artist "Show"
                        'album "Feed"
                        'duration 1830.0
                        'position 42.0
                        'playing #t
                        'identifier "site.jrtx.podlens"
                        'artwork-url ""))
(now-playing-set-command-handler!        ; OS transport commands
 (lambda (cmd arg)                       ; cmd: play pause stop toggle
   ...))                                 ;      next previous seek-by seek-to
(now-playing-clear!)                     ; unpublish
(now-playing-info)                       ; host state (or #f)
(now-playing-os-info)                    ; read the OS surface back (or #f)
```

Input is normalized once in the dispatcher: unknown keys are dropped,
numbers coerced to inexact, strings defaulted, `playing` coerced to a
boolean. Backends never see unvalidated product input.

`now-playing-os-info` is acceptance evidence, not a control path: it reads
the real OS surface back (macOS `MPNowPlayingInfoCenter.nowPlayingInfo`,
Linux `org.freedesktop.DBus.Properties.Get` against the owned MPRIS name)
so a verification run can prove publication instead of trusting the call.

## Platform backends

| Platform | Backend | Surface |
|---|---|---|
| macOS | `glaze/now-playing/now-playing-macos` | public `MediaPlayer.framework`: `MPNowPlayingInfoCenter` publication, `MPRemoteCommandCenter` handlers, `nowPlayingInfo` readback |
| Linux | `glaze/now-playing/now-playing-linux` | host-owned MPRIS2 over GIO/GDBus on the session bus: `org.mpris.MediaPlayer2.<sanitized identifier>`, root + player interfaces, `PropertiesChanged`/`Seeked` signals, real bus readback |
| Windows | `glaze/now-playing/now-playing-stub` | inert: WebView2's web MediaSession → SMTC bridge remains the verified path there |

Missing libraries or a missing session bus degrade to
`now-playing-supported?` → `#f`; startup never crashes because of this
capability. Linux command dispatch runs on the GLib main context; the
dispatcher installs handlers through `now-playing-set-command-handler!`
and the backend wires them to MPRIS methods (`Play`, `Pause`, `Stop`,
`PlayPause`, `Next`, `Previous`, `Seek`, `SetPosition`).

## Verification

`glaze-test/now-playing-test.rkt` runs on all three CI platforms: contract
and normalization everywhere; macOS publication + readback; Linux bus-name
ownership, property readback and a `dbus-send` command round-trip; Windows
stub inertness. Product acceptance matrices should assert the OS surface
(`now-playing-os-info` or the platform probe), never merely that the
publish call returned.

## Boundaries

- The web MediaSession bridge stays in place for in-page metadata and for
  Windows SMTC; host publication is additive, not a replacement there.
- No private macOS APIs (MediaRemote) are used or linked.
- The capability adds no route, no token surface, and no persistence.
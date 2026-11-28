# Scoped power protection

Import `glaze/power` for tasks that must not be interrupted by automatic
system sleep. This is optional and does not prevent forced shutdown,
battery exhaustion or every operating-system suspend override.

```racket
(require glaze/power)
(call-with-keep-awake "Firmware transfer"
  (lambda () (perform-transfer!)))
```

The scoped helper raises before invoking the task if acquisition fails.
Manual acquisition returns an opaque token or #f. Always release a
successful token, preferably using dynamic-wind. Release returns #t on
success and #f for unknown, already released or failed tokens.

| Platform | System | Display |
| --- | --- | --- |
| macOS | IOKit idle assertion | IOKit display assertion |
| Windows | Power request handle | Power request handle |
| Linux | logind sleep inhibitor via systemd-inhibit | Unsupported |

Linux requires systemd-inhibit, a shell and permission to acquire a logind
inhibitor. Its sleep inhibitor may also block explicit suspend requests.
Availability probing is not proof of successful acquisition. On restricted
sessions acquisition can fail. Release is explicit; do not abandon tokens.
The macOS App Nap exemption remains separate from idle-sleep protection.

Native acceptance should compare held and released assertions using
`pmset -g assertions`, `powercfg /requests` or `systemd-inhibit --list`
respectively, including overlapping tokens. Headless unit tests alone do
not attest operating-system behavior.

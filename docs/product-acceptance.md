# Product acceptance for Glaze applications

Glaze supplies a runtime and a verification hook; it does not decide what your
product must do. This page owns the acceptance contract: the smallest evidence
that a packaged Glaze application is actually done, and the difference between
a framework check and a product check.

## Definition of done

An application is acceptable when a fresh install on each supported platform
can complete its first useful task in a real native window, and the same build
survives the release path the product promises (restart, update, rollback,
uninstall). A unit suite, a development screenshot, or a window that merely
opens is not acceptance.

## The scenario record

Write one row per core scenario. The format is deliberately mechanical so a
platform difference cannot hide inside “it works”:

`scenario → initial state → action → visible result → persisted effect → failure/recovery → per-platform presentation → evidence`

| Column | What to record |
| --- | --- |
| Scenario | One user-visible outcome, not an implementation step |
| Initial state | Fresh profile, existing data, offline, signed-out, migrated data |
| Action | The exact interaction, including keyboard path and menu/tray entry |
| Visible result | Text, selection, focus and state the user can observe |
| Persisted effect | File, store key or database row, and its location |
| Failure/recovery | What happens on missing file, denied permission, crash or cancel; how the user recovers |
| Per-platform presentation | Window chrome, shortcut, dialog and menu differences that are intentional |
| Evidence | Command, screenshot, log, artifact digest and run URL |

At minimum record the first-run task, one destructive action with its undo or
confirmation, one cancellation, one restart with restored state, and one
failed dependency (WebView, native library, network) with the recovery path.

## Evidence levels

| Level | What it proves | Typical command |
| --- | --- | --- |
| Framework suite | Your Racket logic and route contracts | `raco test test/` (your application suite) |
| Native window | The real system WebView loads the application and satisfies your baseline checks | `raco glaze verify` |
| Packaged artifact | The built app boots on this platform | `raco glaze measure startup --seconds 3` |
| Installed and updated | Installer, signing, update and rollback behave | the product's own N→N+1 scenario |

Levels do not substitute for each other. `verify` passing does not prove the
packaged artifact starts; a surviving process does not prove the page rendered
or that the update installed.

## Extending `verify.rkt`

`raco glaze init` writes a non-interactive verifier that waits for the window,
checks the title, compares the URL and captures a PNG. Its title wait expects
the scaffold's `Glaze App`; change that assertion when you rename the page.

Extend it toward the first-run task while keeping it non-interactive and
bounded:

- drive the page through the same typed routes the user exercises, or through a
  bootstrap query the frontend understands;
- assert the persisted effect after the window closes where the store is
  file-backed, then start a second window and assert restoration;
- keep a deadline on every wait, and exit nonzero with a printed verdict list;
- never require a human click, a real credential or a network service that CI
  does not control.

The generated `AGENTS.md` in the project names `verify.rkt` as the acceptance
owner; keep that file in review like application code.

## Platform checklist

For every supported platform, exercise:

- launch from the packaged artifact, not only from `racket main.rkt`;
- keyboard reachability, focus order and Escape behavior;
- IME and text input in the main forms, plus scaling and large text;
- file/folder dialogs, including cancel and denied permission;
- window close, reopen and saved geometry;
- menu, tray and global shortcut behavior where the product exposes them;
- the data location, backup/export and deletion path the product promises;
- accessibility roles/names through the platform's inspector, not only DOM.

Anything you cannot run on a platform is missing evidence, not a pass. Record
it as such in the release notes rather than generalizing from another OS.

## Relationship to CI

[The CI contract](ci.md) describes how to gate these checks mechanically.
Product acceptance decides **what** must be true; CI decides **when** it is
verified and what artifact the evidence refers to.

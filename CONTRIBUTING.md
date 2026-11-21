# Contributing to OS+

Thanks for helping. Small, focused pull requests are easiest to review.

## Setup

- Apple silicon Mac, macOS 26, Xcode 26 (Swift 6.2)
- `swift build` builds, `swift test` runs the tests, and `scripts/build-app.sh` installs `/Applications/OS+.app`

## Where things go

| Folder | Put here |
|---|---|
| `Sources/WorkbenchCore` | Anything that can be tested without UI: reading system data, parsing, searching, deciding verdicts. Shell-outs go through `CommandRunning` so tests can feed canned output. |
| `Sources/Workbench` | SwiftUI views and their `@Observable` models. Keep these thin. |
| `Sources/WorkbenchAudioRT` | Real-time audio C code. No allocation, locks or Objective-C on the audio thread. |
| `Tests/WorkbenchCoreTests` | Swift Testing suites. Prefer fixtures captured from a real Mac (with anything personal removed). |

## Ground rules

These are the promises the app makes, so every PR has to keep them:

1. **No network calls.** No analytics, update checks or cloud APIs.
2. **Never delete.** Use `FileManager.trashItem` with a confirmation or Undo.
3. **Act only on a click.** Nothing stops processes, moves files or changes audio by itself.
4. **No drivers or root.** No kernel/audio driver extensions, privileged helpers or `sudo`.
5. **Don't block the UI.** Slow work runs off the main actor.
6. **Keep the bundle id** `local.workbench`, because changing it resets users' permissions.

## Handy debug flags

Run the built binary (`$(swift build -c release --show-bin-path)/Workbench`) with:

| Flag | Does |
|---|---|
| `--debug-window --tab ports` | Shows the popover in a normal window |
| `--snapshot <tab> out.png [height]` | Renders a tab to a PNG off-screen (used for README screenshots) |
| `--search-cli "query"` | Prints file finder results in the terminal |
| `--sound-cli list` | Lists apps using audio (use `scripts/sound-selftest.sh` so the app's own permission applies) |
| `--demo-find "query"` / `--demo-toast` | Opens the finder panel or a toast |

## Pull request checklist

- [ ] `swift build` shows no warnings and `swift test` passes
- [ ] New logic in `WorkbenchCore` has tests
- [ ] UI changes include a before/after screenshot
- [ ] The ground rules above still hold

## Bugs and ideas

Open an issue using a template. For bugs, include your macOS version and Mac model, and the output of the relevant
debug flag if there is one.

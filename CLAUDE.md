# OS+ (code name: Workbench)

macOS menu-bar app (SwiftPM + SwiftUI). Read `CONTRIBUTING.md` for the layout, debug flags and ground rules.
If a local `PLAN.md` exists (the maintainer's notes, gitignored), read it first and add to its progress log.

- Build: `swift build`; test: `swift test`; install: `scripts/build-app.sh` → `/Applications/OS+.app`
- The user-facing name is **OS+**. Keep bundle id `local.workbench`, because changing it resets granted permissions.
- Ground rules: no network, Trash instead of deleting, act only on a click, no drivers or root.

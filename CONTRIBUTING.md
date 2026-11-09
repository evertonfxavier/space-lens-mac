# Contributing

Thanks for helping. SpaceLens is a native macOS app (SwiftUI + AppKit) built with `swiftc` only: there is no Xcode
project and no SwiftPM manifest.

## Requirements

- macOS 14 or later, Xcode or the Command Line Tools with Swift 6.
- Nothing else: no dependencies.

## Workflow

```bash
make check      # lint + tests + build (what CI runs)
make test       # Swift Testing suites (Core + Tests only)
make format     # apply swift-format
make run        # build and open
make snapshots  # screenshots with demo data in build/snapshots
```

1. Fork, create a branch, change code.
2. Add or update tests for anything under `Sources/SpaceLens/Core`. The tests use real temporary directories, not
   mocks of the file system.
3. Run `make check`.
4. Add a line to `CHANGELOG.md` under `## [Unreleased]`.
5. Open a pull request.

## Ground rules

- **Safety first.** Anything that removes data goes through `SafetyGuard` and `Cleaner`. New catalog entries need a
  test, and when in doubt the entry is `review`, not `safe`.
- `Core` must not import SwiftUI or AppKit UI code (the tests compile `Core` alone).
- Unattended routines never ask for a password and never touch system items.
- No network access, no telemetry.
- User-facing strings are in Brazilian Portuguese for now. Localization contributions are welcome.

## Releasing (maintainers)

Releases are automatic. Update `VERSION` and `CHANGELOG.md` (a `## [x.y.z]` section is required) and merge to
`main`. The *Release* workflow tests, builds a universal binary and publishes the GitHub release with the zip, the
dmg and `SHA256SUMS.txt`. If the release already exists for that version, nothing happens.

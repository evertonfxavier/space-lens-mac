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
4. Write the commit (or the PR title, when squash-merging) as a [Conventional Commit](https://www.conventionalcommits.org):
   `feat: …`, `fix: …`, `docs: …`. It decides the next version, see *Releasing* below.
5. Open a pull request.

## Ground rules

- **Safety first.** Anything that removes data goes through `SafetyGuard` and `Cleaner`. New catalog entries need a
  test, and when in doubt the entry is `review`, not `safe`.
- `Core` must not import SwiftUI or AppKit UI code (the tests compile `Core` alone).
- Unattended routines never ask for a password and never touch system items.
- No telemetry. The only network request is the optional, anonymous update check against the GitHub releases API.
- **Every user-facing string goes through `L("…")`** (never a bare `Text("literal")`, SwiftUI would look it up in the
  wrong place). The Brazilian Portuguese text is the key, and `Resources/Localization/<lang>.lproj/Localizable.strings`
  holds the English and Spanish versions. Format strings use `%@` / `%lld` and positional `%1$@` when the word order
  differs. A test fails if a key used in the code is missing from a table, if a table keeps a key nobody uses, if the
  placeholders differ, or if a view hard-codes text.

## Adding a language

1. Copy `Resources/Localization/en.lproj` to `<code>.lproj` and translate the values (keep the keys).
2. Add the case to `AppLanguage` in `Sources/SpaceLens/Core/Localization/Localizer.swift` (its `code`, `nativeName`
   and the `resolve` rule), and list the language in `CFBundleLocalizations` in `Resources/Info.plist.in`.
3. Add the code to the language list in `Tests/LocalizationTests.swift` and run `make check`.

## Releasing

Releases are automatic: nobody edits `VERSION` or `CHANGELOG.md` by hand. On every push to `main` the *Release*
workflow runs `scripts/release.py`, which reads the commits since the latest `v*` tag:

| Commit | Next version |
|---|---|
| `feat: …` | minor (`0.2.1` → `0.3.0`) |
| `fix: …`, `perf: …`, `refactor: …` | patch (`0.2.1` → `0.2.2`) |
| `feat!: …`, or `BREAKING CHANGE:` in the body | major (minor while the version is still `0.x`) |
| `docs`, `chore`, `ci`, `test`, `style`, `build` | no release on their own |

The highest bump wins. When a release is due the workflow writes `VERSION` and the new `CHANGELOG.md` section from the
commit messages, runs lint and the tests, builds a universal binary, commits the two files back to `main`
(`chore(release): x.y.z [skip ci]`) and publishes the GitHub release with the zip, the dmg and `SHA256SUMS.txt`.

- *Actions → Release → Run workflow* forces a patch, minor or major release (or retries a failed one).
- Setting `VERSION` by hand to a version that has no tag still releases exactly that version.
- The workflow pushes to `main` with the built-in token, so branch protection on `main` has to allow it (or the
  release commit step has to move to a pull request).
- `make test-release` runs the planner's tests against throw-away git repositories.

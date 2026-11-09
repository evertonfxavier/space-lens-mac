# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

Sections are written by the release workflow from the Conventional Commits of each release (see CONTRIBUTING.md), and
`VERSION` is bumped by the same workflow. Nothing here needs to be edited by hand.

## [0.2.1] - 2026-11-09

### Added

- Settings and About are now panes of the main window (sidebar). The separate settings window is gone; ⌘, and the
  menu bar panel open the pane. About shows the version, what the app promises, the update check, system info, links
  and a "copy info for support" button.
- Recommendations: tick or clear everything, a whole safety group, or one recommendation with a checkbox.
- Categories: tick items, trash a whole group or a single item (always to the Trash, through the safety guard).
- Duplicates: tick or clear everything or one group; the oldest copy of each group stays.

## [0.2.0] - 2026-11-09

### Added

- Language setting: English, Portuguese, Spanish or Automatic (follows the macOS language). Applies instantly to the
  window, the menu bar panel, the main menu, notifications and the texts of the catalog.
- The menu bar icon and panel can be switched off in Settings. Without it the app keeps its Dock icon so it stays
  reachable.
- Update notice: the app checks the GitHub releases API once a day (can be turned off) and shows a banner in the
  window and a row in the menu bar panel when a newer release exists. "Check now" in Settings. Nothing is installed
  automatically; Download opens the installer in the browser.
- README screenshots in English and Portuguese, regenerated with `make screenshots`.

### Changed

- Sizes and dates follow the chosen language ("61,8 GB" in Portuguese and Spanish, "61.8 GB" in English).
- The explorer shows paths relative to your home folder (`~/Projects/app`).

## [0.1.0] - 2026-11-09

### Added

- Disk scanner (allocated bytes, hard links counted once, symlinks never followed, parallel).
- Catalog that classifies what is using space and whether it can be deleted (Can delete / Review first / Keep).
- Categories, recommendations, explorer with treemap, and duplicate finder.
- Scheduled cleanup routines (hourly, daily, weekly, monthly) with history; unattended routines never ask for a password.
- Menu bar item showing free space, with a popover for quick cleaning.
- Touch ID / password confirmation before cleaning and the system administrator dialog for system items.
- `SafetyGuard`, the last barrier before any removal.

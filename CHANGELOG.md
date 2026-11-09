# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

The release workflow publishes the section whose heading matches the content of the `VERSION` file.

## [Unreleased]

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

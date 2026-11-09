# Changelog

All notable changes are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project uses [Semantic Versioning](https://semver.org/).

The release workflow publishes the section whose heading matches the content of the `VERSION` file.

## [Unreleased]

## [0.1.0] - 2026-11-09

### Added

- Disk scanner (allocated bytes, hard links counted once, symlinks never followed, parallel).
- Catalog that classifies what is using space and whether it can be deleted (Can delete / Review first / Keep).
- Categories, recommendations, explorer with treemap, and duplicate finder.
- Scheduled cleanup routines (hourly, daily, weekly, monthly) with history; unattended routines never ask for a password.
- Menu bar item showing free space, with a popover for quick cleaning.
- Touch ID / password confirmation before cleaning and the system administrator dialog for system items.
- `SafetyGuard`, the last barrier before any removal.

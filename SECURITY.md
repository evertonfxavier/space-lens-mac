# Security policy

SpaceLens deletes files, so bugs in its safety checks matter. The most relevant classes of issue are:

- a path that bypasses `SafetyGuard` (`Sources/SpaceLens/Core/Safety/SafetyGuard.swift`) and gets removed;
- anything that makes the administrator prompt run a command or path the user did not see;
- a routine deleting something it should not (routines must never touch system items or non-cache data).

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting:
**Security → Report a vulnerability** in this repository.

Include the macOS version, the SpaceLens version and the steps to reproduce. You can expect a first answer within a
few days.

## Supported versions

Only the latest release receives fixes.

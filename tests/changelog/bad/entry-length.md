# Changelog

All notable changes to example are listed here, newest first.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/2.0.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). A breaking change is marked **Breaking:**.

## [Unreleased]

### Fixed

- The status line no longer shows a stale mark after a reload.

## [0.2.0] - 2026-03-10

This release adds a quiet mode and makes the warning shorter. Requires Claude Code 2.1.300 or newer; tested against 2.1.310.

### Added

- A `quiet` setting that hides the start-up line.

### Changed

- **Breaking:** the `warn_after` setting is now in minutes instead of seconds; divide your old value by 60.
- The warning now fits on one line, so narrow terminals
  no longer wrap it.

### Removed

- **Breaking:** the `--old` flag of the `status` command is gone; use `--all` instead.

### Security

- CVE-2026-12345: the log no longer keeps the value of a `TOKEN` variable.

## [0.1.1] - 2026-03-10 [YANKED]

A fix for the first release, withdrawn the same day. The one-line install needs 2.1.292 or newer. Requires Claude Code 2.1.287 or newer; tested against 2.1.300.

### Fixed

- Files matched by `src/**/*.md` are read again.

## [0.1.0] - 2026-02-01

The first release. Requires Claude Code 2.1.287 or newer; tested against 2.1.290.

### Added

- Handoffs for long sessions: the plugin writes a note before the context fills up the plugin writes a note before the context fills up the plugin writes a note before the context fills up the plugin writes a note before the context fills up the plugin writes a note before the context fills up the plugin writes a note before the context fills up.

[Unreleased]: https://github.com/example/example/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/example/example/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/example/example/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/example/example/releases/tag/v0.1.0

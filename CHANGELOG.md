# Changelog

All notable changes to brenn-os are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0/).

## [Unreleased]

### Added

- **Repository bootstrap.** Apache-2.0 license and notice, charter README,
  contributor-facing conventions, and the TODO ledger.
- **Commit and push gates.** Secret scanning on staged content at commit time
  and on the pushed range, plus a `Write`/`Edit`-time scan for agent sessions.
  Wired by `make setup-hooks`.
- **CI** — two jobs: `check` (shell lint, via the repo-root `make check` target
  so the gate is reproducible on a fresh clone) and `scrub` (whole-tree secret
  scan with a version- and hash-pinned scanner).

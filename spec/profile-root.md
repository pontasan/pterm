# Pterm Profile Root

## Purpose

All persistent application state is rooted under a single pterm profile directory.
By default this profile root is `~/.pterm`, but the application must support
rebinding the profile root to an arbitrary directory before config, sessions,
workspaces, clipboard files, audit logs, and lock files are resolved.

## Launch Option

- The supported launch option for rebinding the profile root is:
  - `--user-data-dir <directory>`
- When omitted, the application must use `~/.pterm`.

## Requirements

- The profile root is the sole parent directory for:
  - `config.json`
  - `lock`
  - `files/`
  - `sessions/`
  - `sessions/scrollback/`
  - `audit/`
  - `workspaces/`
- A single override operation must update all derived pterm paths together.
- Tests and self-tests must never rely on the default `~/.pterm` profile root.
- Tests must inject a temporary profile root such as `/tmp/.pterm_<timestamp>_<suffix>`
  so the whole pterm tree is isolated, not just the config file.
- Leaving an override scope must restore the previous profile root.
- Directory creation and permission enforcement rules remain unchanged when the
  profile root is overridden.

## Testing Expectations

- Regression tests must assert that overriding the profile root updates all
  derived pterm directories consistently.
- Regression tests must verify that helper utilities for temporary config also
  override the full pterm profile root, not only `config.json`.

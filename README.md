# pterm

A fast, secure, and memory-efficient terminal emulator for macOS.

![pterm demo](Resources/demo.gif)

## Features

- **Single window, multiple terminals** — Manage multiple shell sessions in one window with an integrated overview grid.
- **Memory-controlled scrollback** — Unlike macOS Terminal, scrollback memory is capped and automatically rolled. No more runaway memory from `tail -F`.
- **Metal-accelerated rendering** — GPU-rendered terminal with sRGB color management, glyph atlas caching, and offscreen thumbnail compositing.
- **Shell flexibility** — Defaults to your system shell (typically zsh), with automatic fallback to bash and sh.
- **Full IME support** — Japanese and other multi-byte input via macOS Input Methods with correct cursor positioning.
- **Workspace management** — Organize terminals into named workspaces with persistent notes.
- **Workspace identity overlays** — Hold `Cmd` to reveal deterministic workspace/title headers for focused and split terminals.
- **Dark theme** — Black background, optimized for CLI tools like Claude Code.
- **Code signed and notarized** — Distributed with Developer ID signature and Apple notarization for Gatekeeper compatibility.
- **Zero external dependencies** — Built entirely on macOS system frameworks (AppKit, Metal, Security). No third-party libraries.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode Command Line Tools (for building from source)

## Install

Download the latest `pterm.zip` from [Releases](https://github.com/user/pterm/releases), unzip, and move `pterm.app` to `/Applications`.

## Build from Source

Debug build:

```bash
make debug
open .build/pterm.app
```

Release build:

```bash
make build
```

`make build` runs the full regression test suite before producing the release app bundle.

Run tests:

```bash
make test
```

## Profile Directory

By default, pterm stores its persistent state under `~/.pterm`.

This profile root contains:

- `config.json`
- `sessions/`
- `sessions/scrollback/`
- `workspaces/`
- `audit/`
- `files/`
- `lock`

If no launch option is provided, pterm always uses `~/.pterm`.

You can override the profile root at launch time with:

- `--user-data-dir <directory>`

This means: “treat this directory as the pterm profile root instead of `~/.pterm`.”

Examples:

open .build/pterm.app --args --user-data-dir /tmp/.pterm_profile_dev
```

Or launch the app binary directly:

```bash
.build/pterm.app/Contents/MacOS/PtermApp --user-data-dir /tmp/.pterm_profile_dev
```

This is useful for:

- isolated test runs
- temporary debugging profiles
- running multiple independent pterm environments
- Chrome-style external profile directory management

Profile CPU hot paths:

```bash
make profile-cpu
```

## Signing and Distribution

Sign with a Developer ID certificate:

```bash
make sign IDENTITY='Developer ID Application: Your Name (TEAMID)'
```

Build, sign, notarize, and package in one step:

```bash
make notarize \
  IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  NOTARY_PROFILE='your-notarytool-profile'
```

The notarized app is stapled and verified automatically. Distribute `.build/pterm.zip`.

## Development

This application was built with [Claude Code](https://claude.com/claude-code) and [Codex](https://openai.com/index/codex/).

## License

[MIT](LICENSE)

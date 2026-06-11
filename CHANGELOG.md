# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-06-11

### Added

- `claude --account <name>` wrapper for Windows PowerShell 5.1+ and bash 3.2+/zsh.
- `claude-account` management command: `list`, `add`, `remove`, `use`, `bind`,
  `unbind`, `current`, `version`.
- Automatic per-directory account selection via a committable
  `.claude-account` file (like `.nvmrc`), searched upward from the current
  directory.
- Filesystem-based registry: a profile is a directory under
  `~/.claude-accounts/profiles/<name>/`, or a `<name>.path` redirect file for
  custom config locations. No JSON registry to corrupt, identical format on
  every OS.
- Resolution order: `--account` flag > `claude-account use` (terminal) >
  external `CLAUDE_CONFIG_DIR` > `.claude-account` file > default.
- Installers for both platforms (`install.ps1`, `install.sh`).
- Test suites (Pester 5 and bats) and CI on Windows, Ubuntu and macOS.

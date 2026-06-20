# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.0] - 2026-06-19

### Added

- **Universal Windows support.** The wrapper now works in Command Prompt
  (`cmd.exe`) and Git Bash, not only PowerShell. `install.ps1` is now the
  universal Windows installer: it drops cmd shims under
  `~/.claude-accounts/bin` (first on PATH), wires the PowerShell profile, and
  writes a managed block to `~/.bashrc` for Git Bash. The cmd shims delegate to
  the same PowerShell engine, so there is no third behavior to maintain.
- `claude-account doctor` — health-check that reports the resolved account, the
  real `claude` binary, and whether each shell (PowerShell, cmd, Git Bash) is
  wired up. The fastest way to see *why* skills/agents are landing where they do.
- `claude-account migrate <name> [--from <name>]` — copy skills, agents,
  commands, plugins and usage content from the default account (or another
  profile) into a profile. Credentials and caches are never copied; existing
  data is never overwritten.

### Changed

- `claude-account add` now inherits the full toolset from the default account
  (skills, agents, commands, plugins, settings, rules, output styles, themes,
  keybindings, sessions, projects, history) instead of only `settings.json`.
  Credentials and the identity file are never copied, so each profile still logs
  in on its own. Use `--minimal` (`-Minimal` on PowerShell) for the old
  settings-only behavior.

### Fixed

- Skills, agents and plugins created from cmd or Git Bash no longer land in the
  default `~/.claude` instead of the active profile. Root cause: the wrapper
  only existed in PowerShell, so other shells ran the bare binary against the
  default config dir. It now resolves the account in cmd and Git Bash too.

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

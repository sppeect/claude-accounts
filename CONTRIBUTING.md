# Contributing to claude-accounts

Thanks for your interest! This project is intentionally small: two
self-contained engines (PowerShell and bash) with the same behavior on every
platform, plus thin cmd.exe shims that delegate to the PowerShell engine.

## Layout

| Path | What it is |
| --- | --- |
| `src/ClaudeAccounts.psm1` | Windows engine (PowerShell 5.1+) |
| `src/claude-accounts.sh` | macOS / Linux / Git Bash engine (bash 3.2+ / zsh, sourced) |
| `src/cmd/` | Command Prompt (cmd.exe) shims that delegate to the PowerShell engine |
| `install.ps1` | Universal Windows installer (PowerShell + cmd + Git Bash) |
| `install.sh` | macOS / Linux / Git Bash installer |
| `tests/ClaudeAccounts.Tests.ps1` | Pester 5 suite |
| `tests/claude-accounts.bats` | bats-core suite |

## Ground rules

1. **Feature parity.** Any behavior change must land in BOTH engines
   (commands, resolution order, messages, exit codes) and in both test suites.
   The cmd.exe shims stay thin: they forward argv to the PowerShell engine and
   inherit its behavior automatically. The only logic that lives in a shim is
   the `use` special case (it must set the cmd session's own environment, which
   a child PowerShell cannot). Get-ClaudeExecutable / `_ca_exe` must skip the
   shim dir so the wrapper never resolves to itself.
2. **Compatibility floors.** PowerShell 5.1 (no `??`, no ternary, UTF-8 BOM
   required for non-ASCII) and bash 3.2 (macOS default — no associative
   arrays, no `${var,,}`, no `mapfile`). The shell file must also work when
   sourced from zsh.
3. **Never break the wrapper contract.** The `claude` wrapper must pass argv
   through untouched after the first positional argument, preserve exit codes,
   keep stdin/TTY interactivity intact, and never leak env changes into the
   calling shell.
4. **Tests use the mock, not the real binary.** Both suites isolate with
   `CLAUDE_ACCOUNTS_HOME` / `CLAUDE_ACCOUNTS_DEFAULT_DIR` and a fake `claude`
   executable on PATH. CI must stay green on windows-latest, ubuntu-latest and
   macos-latest.

## Running tests locally

```powershell
# Windows
Invoke-Pester tests/ClaudeAccounts.Tests.ps1
```

```bash
# macOS / Linux
bats tests/claude-accounts.bats
shellcheck -s bash src/claude-accounts.sh
```

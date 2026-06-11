# Contributing to claude-accounts

Thanks for your interest! This project is intentionally small: two
self-contained source files with the same behavior on every platform.

## Layout

| Path | What it is |
| --- | --- |
| `src/ClaudeAccounts.psm1` | Windows implementation (PowerShell 5.1+) |
| `src/claude-accounts.sh` | macOS/Linux implementation (bash 3.2+ / zsh, sourced) |
| `tests/ClaudeAccounts.Tests.ps1` | Pester 5 suite |
| `tests/claude-accounts.bats` | bats-core suite |

## Ground rules

1. **Feature parity.** Any behavior change must land in BOTH implementations
   (commands, resolution order, messages, exit codes) and in both test suites.
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

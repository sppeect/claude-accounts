# claude-accounts

> AWS CLI-style account profiles for Claude Code.

[![CI](https://github.com/sppeect/claude-accounts/actions/workflows/ci.yml/badge.svg)](https://github.com/sppeect/claude-accounts/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** | [Português (Brasil)](docs/README.pt-BR.md)

Run Claude Code with multiple accounts — `claude --account work`, `claude --account personal` — in different terminals at the same time, with per-repository defaults via a committable `.claude-account` file.

Two self-contained implementations with full feature parity:

- `src/ClaudeAccounts.psm1` — Windows PowerShell 5.1+
- `src/claude-accounts.sh` — bash 3.2+ / zsh (sourced from your shell rc)

## The problem

You have more than one Claude account — a work account on a team plan and a personal one, or one account per client — but Claude Code logs into exactly one at a time. Switching means logging out and back in, losing your session, and there is no built-in profile mechanism ([anthropics/claude-code#30031](https://github.com/anthropics/claude-code/issues/30031)).

`claude-accounts` gives each account its own isolated config directory (credentials, settings, history, sessions) and a wrapper that picks the right one per invocation — the same model as `aws --profile`.

## Quick start

### Install

macOS / Linux:

```bash
curl -fsSL https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.sh | bash
```

Windows (PowerShell):

```powershell
iwr -useb https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.ps1 | iex
```

Then restart your shell (or `source ~/.bashrc` / `. $PROFILE`).

### 30 seconds to two accounts

```bash
claude-account add work        # creates the profile and opens the browser login
claude-account add personal    # log in with the other claude.ai account

claude --account work          # this terminal runs the work account...
claude --account personal      # ...while another terminal runs the personal one

cd ~/code/client-project
claude-account bind work       # this repo (and subdirectories) defaults to 'work'
claude                         # no flag needed — resolves to 'work'

claude-account current         # shows the effective account and why
```

Your existing installation is untouched: it is the `default` profile (`~/.claude`), and plain `claude` keeps working exactly as before.

## Commands

| Command | What it does |
| --- | --- |
| `claude --account <name> [...]` | Run Claude Code with the chosen account (alias `-a`, also `--account=<name>`) |
| `claude-account list` | List all profiles, the logged-in email of each, and mark the active one |
| `claude-account add <name>` | Create a profile and open the browser login |
| `claude-account add <name> --no-login` | Create without logging in (login is requested on first run) |
| `claude-account add <name> --path <dir>` | Create a profile whose config dir lives at a custom path |
| `claude-account remove <name> [--force]` | Delete a profile (`--force` required when it has login data) |
| `claude-account use <name>` | Pin an account to this terminal session (`use default` to undo) |
| `claude-account bind <name>` | Bind the current directory to an account (writes `.claude-account`) |
| `claude-account unbind` | Remove the current directory's binding |
| `claude-account current` | Show the effective account, its login, directory and which rule selected it |
| `claude-account version` | Print the installed version |

On Windows the options are PowerShell-style switches: `-NoLogin`, `-Path <dir>`, `-Force`.

The name `default` is reserved for the original installation and cannot be created or removed.

## Account resolution

Highest to lowest priority:

1. **`--account` / `-a` flag** — accepted only before the first positional argument (e.g. `claude --account work -p "..."`). Anything after the first positional argument is passed through to Claude Code untouched, so `claude mcp add x -- cmd -a token` never has its `-a` hijacked.
2. **`$CLAUDE_ACCOUNT`** — set by `claude-account use` for the current terminal session.
3. **`$CLAUDE_CONFIG_DIR` set externally** — if you exported it yourself, the wrapper honors it exactly like the bare binary would (shown as `(external)`).
4. **`.claude-account` file** — searched from the current directory upward, like `.nvmrc`. The first file found decides; an empty file stops the search (a parent's binding never silently leaks down). Windows line endings (CRLF) are tolerated.
5. **`default`** — the original `~/.claude` installation.

When in doubt, `claude-account current` tells you which rule won and why.

## The `.claude-account` file

A one-line text file containing a profile name, exactly like `.nvmrc` contains a Node version:

```bash
cd ~/code/client-project
claude-account bind work       # writes .claude-account with the content "work"
git add .claude-account        # commit it
```

It is meant to be committed. Profile names are local labels — each teammate runs `claude-account add work` once with their own credentials, and from then on the same committed file points everyone to their own "work" account inside that repository. Run `bind` at the repository root so it applies to all subdirectories.

## How it works

Claude Code officially supports the `CLAUDE_CONFIG_DIR` environment variable to relocate its config directory. `claude-accounts` builds on exactly that — no patched binary, no credential juggling:

- **A profile is just a directory.** The registry is the filesystem: `~/.claude-accounts/profiles/<name>/` *is* the config dir, or a `profiles/<name>.path` file whose first line points to a custom directory (`~` is expanded; a `.path` file wins over a directory of the same name). There is no JSON registry to corrupt, and the format is identical on every OS.
- **The environment is set only for the invocation.** The wrapper resolves the account and sets `CLAUDE_CONFIG_DIR` (plus `CLAUDE_ACCOUNT`, so hooks that call `claude` again resolve the *same* account) only for that child process — on bash via a per-invocation env prefix, on PowerShell saved and restored around the call. Nothing leaks into your shell.
- **Terminals are independent.** Because nothing is global, one terminal can run `work` while another runs `personal`, simultaneously, each with its own history and sessions.
- **Wrapper contract.** Exit codes are preserved, stdin and TTY interactivity stay intact, and argv after the first positional argument is passed through byte-for-byte.

## Platform notes

### Windows

- Requires Windows PowerShell 5.1+ (PowerShell 7 also works).
- In scripts, check `$LASTEXITCODE`, **not** `$?` — a wrapper function cannot propagate `$?` from a native executable in PowerShell 5.1. `$LASTEXITCODE` is preserved correctly.
- Processes spawned outside PowerShell (npm scripts, git hooks, `Start-Process`) bypass the wrapper function. Run `claude-account use <name>` first: it exports `CLAUDE_CONFIG_DIR` for the session, and child processes inherit it.
- An unquoted `--` is consumed by PowerShell itself before it reaches the wrapper. Quote it when you need to pass it through: `claude mcp add x '--' cmd -a token`.

### macOS

- Recent Claude Code versions store OAuth credentials in the Keychain **keyed by config dir**, so profiles are fully isolated.
- If you are on an older version where the Keychain entry behaves as a singleton (logging into one profile evicts the other), the workaround is a long-lived token per profile: run `claude setup-token` while each profile is active.

### Linux

- Credentials are stored in a file inside the config dir (`.credentials.json`), so isolation works out of the box.

## Limitations

Honest list — know what you are getting:

- **Settings, plugins and MCP servers are per profile.** `add` copies `settings.json` from the default profile so new accounts inherit your permissions, theme and statusline, but that is a one-time copy at creation. Profiles drift independently afterwards; plugins and MCP registrations must be configured per profile.
- **One shared binary.** All profiles run the same Claude Code installation. Auto-update is serialized by Claude Code's own global lock, so concurrent sessions do not fight over it — but an update applies to every profile at once.
- **`use` is per shell session.** It is an environment variable; new terminals start back at the regular resolution order. For a durable default, use `bind` (per directory) instead.
- **The wrapper is a shell function.** Anything that invokes the `claude` binary without going through your interactive shell bypasses it (see the Windows note above — the same `claude-account use` workaround applies everywhere).

## Comparison with alternatives

| Tool | Approach | Why claude-accounts instead |
| --- | --- | --- |
| cloak | Shell wrapper | bash-only; no Windows/PowerShell support |
| CAAM / claude-swap | Swap files in `~/.claude` globally | Global switch: every terminal changes at once, so no two accounts in parallel |
| claude-profiles (npm) | Profile manager for settings | Does **not** switch accounts — it manages settings profiles, not logins |

`claude-accounts` is per-invocation (parallel accounts), per-directory (`.claude-account`), and works on Windows, macOS and Linux with the same commands.

## Uninstall

macOS / Linux:

```bash
# remove the 'source ~/.claude-accounts/claude-accounts.sh' line from ~/.bashrc / ~/.zshrc
rm -rf ~/.claude-accounts
```

Windows (PowerShell):

```powershell
# remove the Import-Module ClaudeAccounts line from your profile
notepad $PROFILE
Remove-Item -Recurse -Force ~\.claude-accounts
```

Deleting `~/.claude-accounts` deletes the named profiles' logins, history and sessions. Your original `~/.claude` (the `default` profile) is never touched.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The two ground rules: every behavior change lands in **both** implementations (and both test suites — Pester 5 and bats), and the tests never touch the real `claude` binary (they isolate with `CLAUDE_ACCOUNTS_HOME` / `CLAUDE_ACCOUNTS_DEFAULT_DIR` and a mock executable on `PATH`).

## License

[MIT](LICENSE).

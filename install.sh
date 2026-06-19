#!/usr/bin/env bash
# ============================================================================
# claude-accounts installer (bash / zsh)
# https://github.com/sppeect/claude-accounts
#
# Run it straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.sh | bash
#
# What it does:
#   1. Downloads src/claude-accounts.sh into ~/.claude-accounts/
#   2. Creates ~/.claude-accounts/profiles/
#   3. Adds an idempotent source block to your shell rc, delimited by
#      '# >>> claude-accounts >>>' / '# <<< claude-accounts <<<' markers
#      (~/.zshrc for zsh, ~/.bashrc for bash, decided by $SHELL).
#      Piped installs (curl | bash) never prompt; running the saved script in
#      an interactive terminal asks before touching the rc.
#
# Environment overrides:
#   CLAUDE_ACCOUNTS_NO_RC=1        do not touch the shell rc file
#   CLAUDE_ACCOUNTS_HOME=<dir>     install somewhere other than ~/.claude-accounts
#   CLAUDE_ACCOUNTS_RC_FILE=<rc>   write the source block to this file instead
#   CLAUDE_ACCOUNTS_INSTALL_REF    git ref to download from (default: main)
#   CLAUDE_ACCOUNTS_INSTALL_URL    full URL of claude-accounts.sh (tests/mirrors)
# ============================================================================

set -eu

CA_START='# >>> claude-accounts >>>'
CA_END='# <<< claude-accounts <<<'
CA_REF="${CLAUDE_ACCOUNTS_INSTALL_REF:-main}"
CA_URL="${CLAUDE_ACCOUNTS_INSTALL_URL:-https://raw.githubusercontent.com/sppeect/claude-accounts/${CA_REF}/src/claude-accounts.sh}"

# On Windows this installer covers Git Bash / MSYS only. PowerShell and cmd.exe
# are wired up by install.ps1 instead (it also drops the same claude-accounts.sh).
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) CA_WINDOWS=1 ;;
    *)                    CA_WINDOWS="" ;;
esac

ca_download() {
    # $1 = url, $2 = destination file
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        echo "claude-accounts: neither curl nor wget is available - install one of them and retry." >&2
        return 1
    fi
}

# Print a path with the literal text $HOME in place of the home prefix, so the
# line written to the rc keeps working if the home directory ever moves.
ca_home_text() {
    case "$1" in
        "$HOME")   printf '%s' '$HOME' ;;
        "$HOME"/*) printf '%s%s' '$HOME' "${1#"$HOME"}" ;;
        *)         printf '%s' "$1" ;;
    esac
}

# Rewrite the managed block in an rc file: replaces the block between the
# markers if it already exists (idempotent), appends it at the end otherwise.
# $1 = rc file, $2 = block body (the lines between the markers)
ca_write_rc_block() {
    rc="$1"
    body="$2"
    [ -f "$rc" ] || : > "$rc"
    tmp="$rc.claude-accounts.$$"
    {
        if grep -F -q "$CA_START" "$rc" 2>/dev/null; then
            awk -v s="$CA_START" -v e="$CA_END" '
                $0 == s { skip = 1; next }
                skip && $0 == e { skip = 0; next }
                !skip { print }
            ' "$rc"
        else
            cat "$rc"
        fi
    } | awk '{ l[NR] = $0 }
        END { n = NR
              while (n > 0 && l[n] ~ /^[[:space:]]*$/) n--
              for (i = 1; i <= n; i++) print l[i] }' > "$tmp"
    {
        if [ -s "$tmp" ]; then printf '\n'; fi
        printf '%s\n' "$CA_START"
        printf '%s\n' '# Managed by the claude-accounts installer. Do not edit inside this block.'
        printf '%s\n' "$body"
        printf '%s\n' "$CA_END"
    } >> "$tmp"
    cat "$tmp" > "$rc"    # cat, not mv: preserves rc permissions and symlinks
    rm -f "$tmp"
}

main() {
    install_dir="${CLAUDE_ACCOUNTS_HOME:-$HOME/.claude-accounts}"
    target="$install_dir/claude-accounts.sh"
    profiles_dir="$install_dir/profiles"

    echo "Installing claude-accounts into $install_dir ..."
    mkdir -p "$profiles_dir"

    tmp_dl="$install_dir/.claude-accounts.sh.download.$$"
    trap 'rm -f "$tmp_dl"' EXIT
    if ! ca_download "$CA_URL" "$tmp_dl"; then
        echo "claude-accounts: download failed: $CA_URL" >&2
        exit 1
    fi
    if ! grep -q '_ca_resolve' "$tmp_dl" 2>/dev/null; then
        echo "claude-accounts: the downloaded file does not look like claude-accounts.sh ($CA_URL)." >&2
        exit 1
    fi
    mv -f "$tmp_dl" "$target"
    trap - EXIT
    echo "Downloaded: $target"

    src_text="$(ca_home_text "$target")"
    line="[ -f \"$src_text\" ] && . \"$src_text\""
    body="$line"
    if [ -n "${CLAUDE_ACCOUNTS_HOME:-}" ]; then
        # A custom home only works if the sourced module sees it at runtime too.
        body="export CLAUDE_ACCOUNTS_HOME=\"$(ca_home_text "$install_dir")\"
$line"
    fi

    if [ -n "${CLAUDE_ACCOUNTS_RC_FILE:-}" ]; then
        rc_file="$CLAUDE_ACCOUNTS_RC_FILE"
    else
        shell_name="${SHELL:-}"
        shell_name="${shell_name##*/}"
        rc_file=""
        case "$shell_name" in
            zsh)  rc_file="${ZDOTDIR:-$HOME}/.zshrc" ;;
            bash) rc_file="$HOME/.bashrc" ;;
        esac
        # Git Bash sometimes leaves $SHELL unset or non-bash; default to ~/.bashrc.
        if [ -z "$rc_file" ] && [ -n "$CA_WINDOWS" ]; then rc_file="$HOME/.bashrc"; fi
    fi

    rc_updated=""
    if [ "${CLAUDE_ACCOUNTS_NO_RC:-}" = "1" ]; then
        echo ""
        echo "CLAUDE_ACCOUNTS_NO_RC=1 - your shell rc was left untouched."
        echo "To enable claude-accounts, add this line to your shell rc:"
        echo "  $line"
    elif [ -z "$rc_file" ]; then
        echo ""
        echo "claude-accounts: could not map your shell ('${SHELL:-unset}') to an rc file."
        echo "Add this line to your shell rc manually:"
        echo "  $line"
    else
        do_rc=1
        if [ -t 0 ]; then
            printf 'Add the claude-accounts source block to %s? [Y/n] ' "$rc_file"
            answer=''
            read -r answer || true
            case "$answer" in
                [nN]*) do_rc=0 ;;
            esac
        fi
        if [ "$do_rc" = "1" ]; then
            ca_write_rc_block "$rc_file" "$body"
            rc_updated=1
            echo "Updated: $rc_file (managed block between the claude-accounts markers)"
        else
            echo "Skipped. To enable claude-accounts later, add this line to $rc_file:"
            echo "  $line"
        fi
    fi

    echo ""
    echo "claude-accounts installed."
    echo "  Script   : $target"
    echo "  Profiles : $profiles_dir"
    echo ""
    echo "Next steps:"
    if [ -n "$rc_updated" ]; then
        echo "  1. Open a new terminal, or reload now:  source $rc_file"
    else
        echo "  1. Load it in this terminal:            . \"$target\""
    fi
    echo "  2. Create an account:                   claude-account add work"
    echo "  3. Run Claude Code with it:             claude --account work"
    echo "  4. Pin it to a project directory:       claude-account bind work"
    echo "  5. Check the install:                   claude-account doctor"

    if [ -n "$CA_WINDOWS" ]; then
        echo ""
        echo "Detected Windows (Git Bash / MSYS): this configured Git Bash only."
        echo "For PowerShell and Command Prompt (cmd) support too, also run the PowerShell installer:"
        echo "  iwr -useb https://raw.githubusercontent.com/sppeect/claude-accounts/${CA_REF}/install.ps1 | iex"
    fi
}

main "$@"

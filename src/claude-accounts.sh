# ============================================================================
# claude-accounts — multi-account manager for Claude Code (AWS CLI profile style)
# https://github.com/sppeect/claude-accounts            (bash 3.2+ / zsh)
#
# This file must be SOURCED from your shell rc (.bashrc / .zshrc), not executed:
#   source ~/.claude-accounts/claude-accounts.sh
#
# Each account lives in its own CLAUDE_CONFIG_DIR (isolated credentials,
# settings, history and sessions). The `claude` wrapper resolves which account
# to use and sets the variable only for that invocation, so different
# terminals can run different accounts at the same time.
#
# Usage:
#   claude --account work            # run Claude Code with the 'work' account
#   claude-account add work          # create the 'work' profile and log in
#   claude-account bind work         # bind the current directory to 'work'
#   claude-account use work          # pin 'work' to this terminal
#   claude-account list              # list accounts and their logins
#   claude-account current           # show the effective account and why
#
# Account resolution (highest to lowest priority):
#   1. --account / -a flag           (accepted only BEFORE the first positional argument)
#   2. $CLAUDE_ACCOUNT               (set by `claude-account use`)
#   3. $CLAUDE_CONFIG_DIR            (set externally — same contract as the bare binary)
#   4. .claude-account file          (searched from the current directory upward)
#   5. default                       (~/.claude — the original installation)
#
# Registry: a profile named <name> is either a directory
# $CLAUDE_ACCOUNTS_HOME/profiles/<name>/ (the directory IS the config dir) or
# a file profiles/<name>.path whose first line points to a custom config dir.
# ============================================================================

# Hyphenated function names (claude-account) are a parse error in POSIX-mode
# bash — bail out of the source cleanly instead of spraying rc errors.
# shellcheck disable=SC2317  # the exit only runs if the file is executed instead of sourced
case ":${SHELLOPTS:-}:" in
    *:posix:*)
        echo 'claude-accounts: POSIX-mode bash is not supported; skipping load.' >&2
        return 0 2>/dev/null || exit 0
        ;;
esac

# A pre-existing alias named `claude` would break the function definitions below.
unalias claude 2>/dev/null || true
unalias claude-account 2>/dev/null || true

CLAUDE_ACCOUNTS_VERSION="1.0.0"

# Literal TAB, materialized once — never embed the raw byte in patterns, where
# an editor reindent would silently corrupt the parsing.
_CA_TAB="$(printf '\t')"

_ca_home() {
    printf '%s\n' "${CLAUDE_ACCOUNTS_HOME:-$HOME/.claude-accounts}"
}

_ca_default_dir() {
    printf '%s\n' "${CLAUDE_ACCOUNTS_DEFAULT_DIR:-$HOME/.claude}"
}

_ca_profiles_root() {
    printf '%s/profiles\n' "$(_ca_home)"
}

# Locate the real claude binary, bypassing this wrapper function.
# Falls back to the native installer location when PATH does not have it
# (parity with Get-ClaudeExecutable in the PowerShell implementation).
_ca_exe() {
    local found=""
    if [ -n "${ZSH_VERSION:-}" ]; then
        found="$(whence -p claude 2>/dev/null)"
    else
        found="$(type -P claude 2>/dev/null)"
    fi
    if [ -n "$found" ]; then printf '%s\n' "$found"; return 0; fi
    if [ -x "$HOME/.local/bin/claude" ]; then printf '%s\n' "$HOME/.local/bin/claude"; return 0; fi
    if [ -x "$HOME/.claude/local/claude" ]; then printf '%s\n' "$HOME/.claude/local/claude"; return 0; fi
    return 1
}

# Trim whitespace, Windows CR and a leading UTF-8 BOM from a string
# (markers and .path files may be written by Windows editors or PowerShell).
_ca_trim() {
    local s="$1" bom
    bom="$(printf '\357\273\277')"
    s="${s#"$bom"}"
    printf '%s' "$s" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Expand a leading ~ in a path read from a .path redirect file.
_ca_expand_tilde() {
    # shellcheck disable=SC2088  # the quoted '~/' is matched/stripped literally on purpose
    case "$1" in
        '~') printf '%s\n' "$HOME" ;;
        '~/'*) printf '%s/%s\n' "$HOME" "${1#"~/"}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# List profile names, one per line ('default' first, no duplicates even when
# a <name>/ directory and a <name>.path redirect coexist).
_ca_names() {
    {
        printf 'default\n'
        local root entry name
        root="$(_ca_profiles_root)"
        if [ -d "$root" ]; then
            # zsh aborts on globs with no matches (NOMATCH); scope null_glob
            # to this function only.
            if [ -n "${ZSH_VERSION:-}" ]; then setopt local_options null_glob; fi
            for entry in "$root"/*; do
                [ -e "$entry" ] || continue
                name="${entry##*/}"
                if [ -d "$entry" ]; then
                    [ "$name" = "default" ] && continue
                    printf '%s\n' "$name"
                else
                    case "$name" in
                        *.path)
                            name="${name%.path}"
                            [ -n "$name" ] && [ "$name" != "default" ] && printf '%s\n' "$name"
                            ;;
                    esac
                fi
            done
        fi
    } | awk '!seen[$0]++'
}

# Resolve a profile name to its config dir. Prints the dir, returns 1 if unknown.
# A non-empty <name>.path redirect wins over a <name>/ directory; an empty
# redirect falls back to the directory (parity with the PowerShell registry).
_ca_dir_for() {
    local name="$1" root pathfile target
    [ -z "$name" ] && return 1
    if [ "$name" = "default" ]; then
        _ca_default_dir
        return 0
    fi
    root="$(_ca_profiles_root)"
    pathfile="$root/$name.path"
    if [ -f "$pathfile" ]; then
        IFS= read -r target < "$pathfile" || true
        target="$(_ca_trim "$target")"
        if [ -n "$target" ]; then
            if [ -d "$root/$name" ]; then
                printf '%s\n' "claude-accounts: profile '$name' has both a directory and a .path file — the .path file wins." >&2
            fi
            _ca_expand_tilde "$target"
            return 0
        fi
        printf '%s\n' "claude-accounts: redirect file $pathfile is empty — falling back to the profile directory if present." >&2
    fi
    if [ -d "$root/$name" ]; then
        printf '%s\n' "$root/$name"
        return 0
    fi
    return 1
}

_ca_known() {
    _ca_dir_for "$1" >/dev/null 2>&1
}

# Find a .claude-account marker walking up from $PWD (like .nvmrc).
# Prints "name<TAB>file". The first marker found decides — an empty marker
# stops the walk (a parent's binding must not silently leak down).
_ca_find_marker() {
    local dir="$PWD" file name
    [ -d "$dir" ] || return 1
    while :; do
        file="${dir%/}/.claude-account"
        if [ -f "$file" ]; then
            name=""
            IFS= read -r name < "$file" || true
            name="$(_ca_trim "$name")"
            if [ -n "$name" ]; then
                printf '%s\t%s\n' "$name" "$file"
                return 0
            fi
            printf '%s\n' "claude-accounts: $file is empty — account binding ignored (delete it or run: claude-account bind <name>)." >&2
            return 1
        fi
        [ "$dir" = "/" ] && break
        dir="${dir%/*}"
        [ -z "$dir" ] && dir="/"
    done
    return 1
}

# Decide which account to use. Prints "name<TAB>dir<TAB>source".
_ca_resolve() {
    local explicit="$1" name marker mname mfile env_account_invalid=""

    if [ -n "$explicit" ]; then
        if ! _ca_known "$explicit"; then
            printf '%s\n' "claude-accounts: account '$explicit' does not exist. Available: $(_ca_names | tr '\n' ' '). Create it with: claude-account add $explicit" >&2
            return 1
        fi
        if marker="$(_ca_find_marker)"; then
            mname="${marker%%"$_CA_TAB"*}"; mfile="${marker#*"$_CA_TAB"}"
            if [ "$mname" != "$explicit" ]; then
                printf '%s\n' "claude-accounts: this directory is bound to '$mname' ($mfile), but you asked for '--account $explicit'. Proceeding with '$explicit'." >&2
            fi
        fi
        printf '%s\t%s\t%s\n' "$explicit" "$(_ca_dir_for "$explicit")" "--account flag"
        return 0
    fi

    if [ -n "${CLAUDE_ACCOUNT:-}" ]; then
        name="$(_ca_trim "$CLAUDE_ACCOUNT")"
        if _ca_known "$name"; then
            printf '%s\t%s\t%s\n' "$name" "$(_ca_dir_for "$name")" "claude-account use (this terminal)"
            return 0
        fi
        env_account_invalid=1
        printf '%s\n' "claude-accounts: CLAUDE_ACCOUNT='$name' does not match any registered account — ignoring. (Clear it with: claude-account use default)" >&2
    fi

    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
        if [ -n "$env_account_invalid" ]; then
            # Residual pair from a `use` for an account that no longer exists.
            printf '%s\n' "claude-accounts: also ignoring the residual CLAUDE_CONFIG_DIR ($CLAUDE_CONFIG_DIR). Run: claude-account use default" >&2
        else
            if marker="$(_ca_find_marker)"; then
                mname="${marker%%"$_CA_TAB"*}"; mfile="${marker#*"$_CA_TAB"}"
                printf '%s\n' "claude-accounts: CLAUDE_CONFIG_DIR is set in the environment and takes priority — this directory's binding ($mfile -> '$mname') was ignored." >&2
            fi
            printf '%s\t%s\t%s\n' "(external)" "$CLAUDE_CONFIG_DIR" "pre-existing CLAUDE_CONFIG_DIR in the environment"
            return 0
        fi
    fi

    if marker="$(_ca_find_marker)"; then
        mname="${marker%%"$_CA_TAB"*}"; mfile="${marker#*"$_CA_TAB"}"
        if _ca_known "$mname"; then
            printf '%s\t%s\t%s\n' "$mname" "$(_ca_dir_for "$mname")" "file $mfile"
            return 0
        fi
        printf '%s\n' "claude-accounts: $mfile points to unknown account '$mname'. Create it with: claude-account add $mname" >&2
    fi

    printf '%s\t%s\t%s\n' "default" "$(_ca_default_dir)" "default (~/.claude)"
    return 0
}

# Read the logged-in email from a config dir's .claude.json, if any.
_ca_email() {
    local dir="$1" state
    state="$dir/.claude.json"
    [ -f "$state" ] || return 1
    grep -o '"emailAddress"[[:space:]]*:[[:space:]]*"[^"]*"' "$state" 2>/dev/null \
        | head -n 1 \
        | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/'
}

# Run the real claude binary with the resolved account's environment.
# $1=name $2=dir, remaining args go to the binary.
_ca_invoke() {
    local name="$1" dir="$2" exe
    shift 2
    exe="$(_ca_exe)"
    if [ -z "$exe" ]; then
        printf '%s\n' "claude-accounts: claude binary not found on PATH. Install Claude Code first." >&2
        return 1
    fi
    case "$name" in
        default)
            env -u CLAUDE_CONFIG_DIR -u CLAUDE_ACCOUNT "$exe" "$@"
            ;;
        '(external)')
            env -u CLAUDE_ACCOUNT "$exe" "$@"
            ;;
        *)
            if [ -z "$dir" ]; then
                printf '%s\n' "claude-accounts: account '$name' resolved to an empty directory — check $(_ca_profiles_root)." >&2
                return 1
            fi
            CLAUDE_CONFIG_DIR="$dir" CLAUDE_ACCOUNT="$name" "$exe" "$@"
            ;;
    esac
}

# Wrapper for the claude binary with --account/-a support and automatic
# per-directory selection (.claude-account). The flag is only interpreted
# BEFORE the first positional argument — everything else is passed through
# intact, so `claude mcp add x -- cmd -a token` never has its '-a' hijacked.
claude() {
    local explicit="" resolved name dir tail
    while [ $# -gt 0 ]; do
        case "$1" in
            --account|-a)
                if [ $# -lt 2 ]; then
                    printf '%s\n' "claude-accounts: usage: claude --account <name>. Available: $(_ca_names | tr '\n' ' ')" >&2
                    return 1
                fi
                explicit="$2"
                shift 2
                ;;
            --account=?*)
                explicit="${1#--account=}"
                shift
                ;;
            --account=)
                printf '%s\n' "claude-accounts: usage: claude --account=<name> (the value is empty). Available: $(_ca_names | tr '\n' ' ')" >&2
                return 1
                ;;
            *)
                break
                ;;
        esac
    done

    for tail in "$@"; do
        case "$tail" in
            --account|--account=*)
                printf '%s\n' "claude-accounts: found '$tail' after the first positional argument — the account flag only applies at the start. Passing it through to claude uninterpreted." >&2
                break
                ;;
        esac
    done

    resolved="$(_ca_resolve "$explicit")" || return 1
    name="$(printf '%s' "$resolved" | cut -f1)"
    dir="$(printf '%s' "$resolved" | cut -f2)"
    _ca_invoke "$name" "$dir" "$@"
}

claude-account() {
    local cmd="${1:-help}" name="${2:-}" custom_path="" no_login="" force=""
    if [ $# -gt 0 ]; then shift; fi
    if [ $# -gt 0 ]; then shift; fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --path)
                if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                    printf '%s\n' "claude-accounts: --path requires a value" >&2
                    return 1
                fi
                custom_path="$2"; shift 2
                ;;
            --path=?*) custom_path="${1#--path=}"; shift ;;
            --path=) printf '%s\n' "claude-accounts: --path requires a value" >&2; return 1 ;;
            --no-login) no_login=1; shift ;;
            --force|-f) force=1; shift ;;
            *) printf '%s\n' "claude-accounts: unknown option '$1'" >&2; return 1 ;;
        esac
    done

    local profiles_root
    profiles_root="$(_ca_profiles_root)"

    case "$cmd" in

        list)
            local active="" resolved n dir email login flag
            resolved="$(_ca_resolve "")" && active="$(printf '%s' "$resolved" | cut -f1)"
            printf '%-2s %-16s %-38s %s\n' '' 'ACCOUNT' 'LOGIN' 'DIRECTORY'
            _ca_names | while IFS= read -r n; do
                dir="$(_ca_dir_for "$n")" || continue
                email="$(_ca_email "$dir")"
                if [ -n "$email" ]; then
                    login="$email"
                elif [ -f "$dir/.credentials.json" ]; then
                    login="(logged in)"
                else
                    login="(no login - run: claude --account $n)"
                fi
                flag=""
                [ "$n" = "$active" ] && flag="*"
                printf '%-2s %-16s %-38s %s\n' "$flag" "$n" "$login" "$dir"
            done
            ;;

        add)
            if [ -z "$name" ]; then printf '%s\n' "usage: claude-account add <name> [--path <dir>] [--no-login]" >&2; return 1; fi
            case "$name" in
                [A-Za-z0-9]*) : ;;
                *) printf '%s\n' "claude-accounts: invalid name '$name'. Use letters, digits, hyphen and underscore." >&2; return 1 ;;
            esac
            case "$name" in
                *[!A-Za-z0-9_-]*) printf '%s\n' "claude-accounts: invalid name '$name'. Use letters, digits, hyphen and underscore." >&2; return 1 ;;
            esac
            if _ca_known "$name"; then
                printf '%s\n' "claude-accounts: account '$name' already exists ($(_ca_dir_for "$name"))." >&2
                return 1
            fi
            mkdir -p "$profiles_root"
            local dir
            if [ -n "$custom_path" ]; then
                dir="$(_ca_expand_tilde "$custom_path")"
                case "$dir" in
                    /*) : ;;
                    *) dir="$PWD/$dir" ;;
                esac
                mkdir -p "$dir"
                # Normalize '..' components before recording (parity with the
                # PowerShell GetFullPath behavior).
                dir="$(cd "$dir" && pwd)"
                printf '%s\n' "$dir" > "$profiles_root/$name.path"
            else
                dir="$profiles_root/$name"
                mkdir -p "$dir"
            fi

            # Inherit preferences (permissions, theme, statusline) from default.
            if [ -f "$(_ca_default_dir)/settings.json" ] && [ ! -f "$dir/settings.json" ]; then
                cp "$(_ca_default_dir)/settings.json" "$dir/settings.json"
            fi

            printf '%s\n' "Account '$name' created at $dir"
            if [ -n "$no_login" ]; then
                printf '%s\n' "To authenticate later: claude --account $name  (login will be requested on first run)"
                return 0
            fi
            printf '%s\n' "Opening login in the browser — sign in with the claude.ai account that belongs to '$name'."
            _ca_invoke "$name" "$dir" auth login
            ;;

        remove)
            if [ -z "$name" ]; then printf '%s\n' "usage: claude-account remove <name> [--force]" >&2; return 1; fi
            if [ "$name" = "default" ]; then printf '%s\n' "claude-accounts: the 'default' account (~/.claude) cannot be removed." >&2; return 1; fi

            # Handle a .path redirect first (even an empty/orphaned one must be
            # deletable through the tool).
            local pathfile="$profiles_root/$name.path" dir
            if [ -f "$pathfile" ]; then
                dir="$(_ca_dir_for "$name" 2>/dev/null)" || dir="(unresolved)"
                if [ "${CLAUDE_ACCOUNT:-}" = "$name" ]; then
                    unset CLAUDE_ACCOUNT CLAUDE_CONFIG_DIR
                    printf '%s\n' "This terminal was using '$name' — switched back to 'default'."
                fi
                rm -f "$pathfile"
                printf '%s\n' "Account '$name' removed (redirect file deleted; the target directory $dir was NOT touched)."
                return 0
            fi

            if ! _ca_known "$name"; then printf '%s\n' "claude-accounts: account '$name' does not exist." >&2; return 1; fi

            if [ "${CLAUDE_ACCOUNT:-}" = "$name" ]; then
                unset CLAUDE_ACCOUNT CLAUDE_CONFIG_DIR
                printf '%s\n' "This terminal was using '$name' — switched back to 'default'."
            fi

            dir="$profiles_root/$name"
            if [ ! -d "$dir" ]; then
                printf '%s\n' "claude-accounts: could not locate the profile entry for '$name' under $profiles_root." >&2
                return 1
            fi
            if [ -L "$dir" ]; then
                # Symlink: removing it only deletes the link, never the
                # target's content — no --force needed.
                rm "$dir"
                printf '%s\n' "Link $dir removed (target content preserved)."
                return 0
            fi
            if { [ -f "$dir/.credentials.json" ] || [ -f "$dir/.claude.json" ]; } && [ -z "$force" ]; then
                printf '%s\n' "claude-accounts: account '$name' has login data in $dir. Removing the profile deletes it permanently — re-run with --force if you are sure." >&2
                return 1
            fi
            rm -rf "$dir"
            printf '%s\n' "Account '$name' removed ($dir deleted)."
            ;;

        use)
            if [ -z "$name" ]; then printf '%s\n' "usage: claude-account use <name>   (use \"default\" to go back to normal)" >&2; return 1; fi
            local external=""
            if [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -z "${CLAUDE_ACCOUNT:-}" ]; then external=1; fi
            if [ "$name" = "default" ]; then
                if [ -n "$external" ]; then
                    printf '%s\n' "claude-accounts: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR was set outside this tool — removing it from the session; set it again manually if you need it." >&2
                fi
                unset CLAUDE_ACCOUNT CLAUDE_CONFIG_DIR
                printf '%s\n' "This terminal is back on the 'default' account (~/.claude)."
                return 0
            fi
            if ! _ca_known "$name"; then
                printf '%s\n' "claude-accounts: account '$name' does not exist. Accounts: $(_ca_names | tr '\n' ' ')" >&2
                return 1
            fi
            if [ -n "$external" ]; then
                printf '%s\n' "claude-accounts: CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR was set outside this tool and will be overwritten in this session ('claude-account use default' will not restore it)." >&2
            fi
            CLAUDE_ACCOUNT="$name"
            CLAUDE_CONFIG_DIR="$(_ca_dir_for "$name")"
            export CLAUDE_ACCOUNT CLAUDE_CONFIG_DIR
            printf '%s\n' "This terminal now uses account '$name'. (This session only.)"
            ;;

        current)
            local resolved n dir src email
            resolved="$(_ca_resolve "")" || return 1
            n="$(printf '%s' "$resolved" | cut -f1)"
            dir="$(printf '%s' "$resolved" | cut -f2)"
            src="$(printf '%s' "$resolved" | cut -f3)"
            email="$(_ca_email "$dir")"
            [ -z "$email" ] && email="(no login)"
            printf 'Account   : %s\nLogin     : %s\nDirectory : %s\nSource    : %s\n' "$n" "$email" "$dir" "$src"
            ;;

        bind)
            if [ -z "$name" ]; then printf '%s\n' "usage: claude-account bind <name>   (creates .claude-account in the current directory)" >&2; return 1; fi
            if ! _ca_known "$name"; then
                printf '%s\n' "claude-accounts: account '$name' does not exist. Create it first with: claude-account add $name" >&2
                return 1
            fi
            printf '%s\n' "$name" > "$PWD/.claude-account"
            printf '%s\n' "Directory bound to account '$name' ($PWD/.claude-account)."
            printf '%s\n' "Run it at the repository root so it applies to all subdirectories. Commitable, like an .nvmrc."
            ;;

        unbind)
            if [ -f "$PWD/.claude-account" ]; then
                rm "$PWD/.claude-account"
                printf '%s\n' "Binding removed ($PWD/.claude-account)."
            else
                printf '%s\n' "No .claude-account file in this directory."
            fi
            ;;

        version)
            printf '%s\n' "claude-accounts $CLAUDE_ACCOUNTS_VERSION (https://github.com/sppeect/claude-accounts)"
            ;;

        *)
            cat <<'EOF'

claude-account — Claude Code account profiles (AWS CLI style)

  claude-account list              list accounts and who is logged into each
  claude-account add <name>        create an account and open the browser login
  claude-account add <name> --no-login   create without logging in (login on first run)
  claude-account remove <name> [--force] delete a profile (--force when it has login data)
  claude-account use <name>        pin the account to this terminal (use default to undo)
  claude-account bind <name>       bind the current directory to an account (.claude-account)
  claude-account unbind            remove the current directory binding
  claude-account current           show the effective account and where it came from

  claude --account <name> [...]    run Claude Code with the chosen account

Priority: --account > use (terminal) > external CLAUDE_CONFIG_DIR > .claude-account (directory) > default

EOF
            ;;
    esac
}

# ----------------------------------------------------------------------------
# Completions
# ----------------------------------------------------------------------------
if [ -n "${ZSH_VERSION:-}" ]; then
    # shellcheck disable=SC2034,SC2206,SC2296  # zsh-only function: compadd -a reads the
    # arrays by name and ${(f)...} is zsh expansion syntax; shellcheck parses bash.
    _claude_account_zsh() {
        local -a subcmds accounts
        subcmds=(list add remove use current bind unbind version help)
        if (( CURRENT == 2 )); then
            compadd -a subcmds
        elif (( CURRENT == 3 )); then
            accounts=(${(f)"$(_ca_names 2>/dev/null)"})
            compadd -a accounts
        fi
    }
    if command -v compdef >/dev/null 2>&1; then
        compdef _claude_account_zsh claude-account
    elif autoload -Uz add-zsh-hook 2>/dev/null; then
        # compinit has not run yet at source time — register the completion
        # once, on the first prompt after the user's compinit.
        _ca_compdef_hook() {
            command -v compdef >/dev/null 2>&1 || return 0
            compdef _claude_account_zsh claude-account
            add-zsh-hook -d precmd _ca_compdef_hook
            unfunction _ca_compdef_hook
        }
        add-zsh-hook precmd _ca_compdef_hook
    fi
elif [ -n "${BASH_VERSION:-}" ]; then
    # shellcheck disable=SC2207  # compgen emits one word per line; the canonical
    # COMPREPLY idiom is fine here (mapfile does not exist in bash 3.2 on macOS).
    _claude_account_bash() {
        local cur="${COMP_WORDS[COMP_CWORD]}"
        if [ "$COMP_CWORD" -eq 1 ]; then
            COMPREPLY=($(compgen -W "list add remove use current bind unbind version help" -- "$cur"))
        elif [ "$COMP_CWORD" -eq 2 ]; then
            COMPREPLY=($(compgen -W "$(_ca_names 2>/dev/null | tr '\n' ' ')" -- "$cur"))
        fi
    }
    complete -F _claude_account_bash claude-account
fi

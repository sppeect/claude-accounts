#!/usr/bin/env bats
# ============================================================================
# bats-core suite for claude-accounts (src/claude-accounts.sh).
# Mirrors the coverage of the Pester suite for ClaudeAccounts.psm1.
#
# Notes:
# - bats runs every @test in its own subshell, so `claude-account use` only
#   affects the current test; use+wrapper combos live inside a single @test.
# - `run` itself executes in a subshell: env mutations made by the command
#   under `run` are not visible afterwards. Where the test must observe env
#   changes (use/remove clearing the pair) the function is called directly.
# - The real claude binary is NEVER used: a mock placed first on PATH prints
#   "MOCK cfg=<CLAUDE_CONFIG_DIR> acct=<CLAUDE_ACCOUNT> args=<argv>" and
#   exits with ${MOCK_EXIT:-0}.
# - Several source messages contain an em dash (non-ASCII); this file is
#   ASCII-only, so those asserts match the exact substrings on either side.
# ============================================================================

setup() {
    TEST_TMP="$(mktemp -d)"

    # Isolate the registry and the default account from the real ones.
    export CLAUDE_ACCOUNTS_HOME="$TEST_TMP/accounts-home"
    export CLAUDE_ACCOUNTS_DEFAULT_DIR="$TEST_TMP/default-claude"
    mkdir -p "$CLAUDE_ACCOUNTS_HOME" "$CLAUDE_ACCOUNTS_DEFAULT_DIR"
    PROFILES="$CLAUDE_ACCOUNTS_HOME/profiles"

    unset CLAUDE_ACCOUNT CLAUDE_CONFIG_DIR MOCK_EXIT

    # Mock claude binary, first on PATH (found by `type -P`, bypassing the
    # wrapper function).
    MOCK_BIN="$TEST_TMP/bin"
    mkdir -p "$MOCK_BIN"
    cat > "$MOCK_BIN/claude" <<'MOCK'
#!/usr/bin/env bash
printf 'MOCK cfg=%s acct=%s args=%s\n' "${CLAUDE_CONFIG_DIR-}" "${CLAUDE_ACCOUNT-}" "$*"
exit "${MOCK_EXIT:-0}"
MOCK
    chmod +x "$MOCK_BIN/claude"
    PATH="$MOCK_BIN:$PATH"

    # Clean working directory (no .claude-account markers in the ancestry).
    WORK_DIR="$TEST_TMP/workdir"
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR"

    # The script is designed to be sourced, never executed.
    source "$BATS_TEST_DIRNAME/../src/claude-accounts.sh"
}

teardown() {
    cd / || true
    if [ -n "${TEST_TMP-}" ]; then rm -rf "$TEST_TMP"; fi
}

# Create a profile without triggering the login flow.
make_account() {
    claude-account add "$1" --no-login > /dev/null
}

# ----------------------------------------------------------------------------
# claude-account add
# ----------------------------------------------------------------------------

@test "add creates a directory profile and prints the no-login hint" {
    run claude-account add work --no-login
    [ "$status" -eq 0 ]
    [ -d "$PROFILES/work" ]
    [ "${lines[0]}" = "Account 'work' created at $PROFILES/work" ]
    [ "${lines[1]}" = "To authenticate later: claude --account work  (login will be requested on first run)" ]
}

@test "add without --no-login runs 'auth login' under the new account" {
    run claude-account add work
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Account 'work' created at $PROFILES/work" ]
    [[ "${lines[1]}" == "Opening login in the browser"* ]]
    [ "${lines[2]}" = "MOCK cfg=$PROFILES/work acct=work args=auth login" ]
}

@test "add --path creates a .path redirect and resolution follows it" {
    target="$TEST_TMP/custom-cfg"
    run claude-account add pers --no-login --path "$target"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Account 'pers' created at $target" ]
    [ -f "$PROFILES/pers.path" ]
    [ -d "$target" ]
    [ "$(head -n 1 "$PROFILES/pers.path")" = "$target" ]

    run claude --account pers
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$target acct=pers args=" ]

    run claude-account list
    [[ "$output" == *"pers"* ]]
    [[ "$output" == *"$target"* ]]
}

@test "add rejects invalid names" {
    run claude-account add 'bad name'
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: invalid name 'bad name'. Use letters, digits, hyphen and underscore."* ]]

    run claude-account add '.dotfirst'
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: invalid name '.dotfirst'. Use letters, digits, hyphen and underscore."* ]]
}

@test "add rejects a duplicate account" {
    make_account work
    run claude-account add work --no-login
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'work' already exists ($PROFILES/work)."* ]]
}

@test "add refuses the reserved name 'default'" {
    run claude-account add default --no-login
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'default' already exists ($CLAUDE_ACCOUNTS_DEFAULT_DIR)."* ]]
}

@test "add without a name prints usage and fails" {
    run claude-account add
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: claude-account add <name> [--path <dir>] [--no-login]"* ]]
}

@test "add copies settings.json from the default account" {
    printf '%s\n' '{"theme":"dark"}' > "$CLAUDE_ACCOUNTS_DEFAULT_DIR/settings.json"
    make_account work
    [ -f "$PROFILES/work/settings.json" ]
    [ "$(cat "$PROFILES/work/settings.json")" = '{"theme":"dark"}' ]
}

@test "claude-account rejects unknown options" {
    run claude-account add work --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: unknown option '--bogus'"* ]]
    [ ! -d "$PROFILES/work" ]
}

# ----------------------------------------------------------------------------
# claude-account list
# ----------------------------------------------------------------------------

@test "list shows default plus registered accounts with login status" {
    make_account work
    run claude-account list
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"ACCOUNT"*"LOGIN"*"DIRECTORY"* ]]
    [[ "$output" == *"default"* ]]
    [[ "$output" == *"$CLAUDE_ACCOUNTS_DEFAULT_DIR"* ]]
    [[ "$output" == *"(no login - run: claude --account work)"* ]]
    [[ "$output" == *"$PROFILES/work"* ]]
}

@test "list marks the active account and reports '(logged in)' from credentials" {
    make_account work
    touch "$PROFILES/work/.credentials.json"
    claude-account use work > /dev/null
    run claude-account list
    [ "$status" -eq 0 ]
    [[ "$output" == *"*  work"* ]]
    [[ "$output" == *"(logged in)"* ]]
}

@test "list shows the email read from .claude.json" {
    make_account work
    printf '%s\n' '{"oauthAccount":{"emailAddress":"work@example.com"}}' > "$PROFILES/work/.claude.json"
    run claude-account list
    [ "$status" -eq 0 ]
    [[ "$output" == *"work@example.com"* ]]
}

# ----------------------------------------------------------------------------
# claude-account remove
# ----------------------------------------------------------------------------

@test "remove deletes a directory profile without login data" {
    make_account work
    run claude-account remove work
    [ "$status" -eq 0 ]
    [[ "$output" == *"Account 'work' removed ($PROFILES/work deleted)."* ]]
    [ ! -d "$PROFILES/work" ]
}

@test "remove guards login data behind --force" {
    make_account work
    touch "$PROFILES/work/.credentials.json"
    run claude-account remove work
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'work' has login data in $PROFILES/work. Removing the profile deletes it permanently"* ]]
    [[ "$output" == *"re-run with --force if you are sure."* ]]
    [ -d "$PROFILES/work" ]

    run claude-account remove work --force
    [ "$status" -eq 0 ]
    [[ "$output" == *"Account 'work' removed ($PROFILES/work deleted)."* ]]
    [ ! -d "$PROFILES/work" ]
}

@test "remove guard also triggers on .claude.json alone" {
    make_account work
    touch "$PROFILES/work/.claude.json"
    run claude-account remove work
    [ "$status" -eq 1 ]
    [[ "$output" == *"has login data in $PROFILES/work"* ]]
    [ -d "$PROFILES/work" ]
}

@test "remove of a .path profile deletes only the redirect file" {
    target="$TEST_TMP/custom-cfg"
    claude-account add pers --no-login --path "$target" > /dev/null
    touch "$target/.credentials.json"
    run claude-account remove pers
    [ "$status" -eq 0 ]
    [[ "$output" == *"Account 'pers' removed (redirect file deleted; the target directory $target was NOT touched)."* ]]
    [ ! -f "$PROFILES/pers.path" ]
    [ -d "$target" ]
    [ -f "$target/.credentials.json" ]
}

@test "remove refuses the default account" {
    run claude-account remove default
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: the 'default' account (~/.claude) cannot be removed."* ]]
}

@test "remove of an unknown account fails" {
    run claude-account remove nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'nope' does not exist."* ]]
}

@test "remove without a name prints usage and fails" {
    run claude-account remove
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: claude-account remove <name> [--force]"* ]]
}

@test "remove of the account pinned with use clears the env pair" {
    make_account work
    claude-account use work > /dev/null
    run claude-account remove work
    [ "$status" -eq 0 ]
    [[ "$output" == *"This terminal was using 'work'"* ]]
    [[ "$output" == *"switched back to 'default'."* ]]

    # `run` is a subshell, so repeat directly to observe the env clearing.
    make_account other
    claude-account use other > /dev/null
    claude-account remove other > /dev/null
    [ -z "${CLAUDE_ACCOUNT-}" ]
    [ -z "${CLAUDE_CONFIG_DIR-}" ]
}

# ----------------------------------------------------------------------------
# Resolution priorities (flag > use > external CLAUDE_CONFIG_DIR > marker > default)
# ----------------------------------------------------------------------------

@test "priority 1: --account flag beats the account pinned with use" {
    make_account work
    make_account personal
    claude-account use work > /dev/null
    run claude --account personal hello
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/personal acct=personal args=hello" ]
}

@test "priority 2: CLAUDE_ACCOUNT (use) beats an external CLAUDE_CONFIG_DIR" {
    make_account work
    export CLAUDE_CONFIG_DIR="$TEST_TMP/external-cfg"
    export CLAUDE_ACCOUNT="work"
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "priority 3: external CLAUDE_CONFIG_DIR beats the directory marker" {
    make_account work
    claude-account bind work > /dev/null
    export CLAUDE_CONFIG_DIR="$TEST_TMP/external-cfg"
    run claude
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"CLAUDE_CONFIG_DIR is set in the environment and takes priority"* ]]
    [[ "${lines[0]}" == *"($WORK_DIR/.claude-account -> 'work') was ignored."* ]]
    # '(external)': CLAUDE_CONFIG_DIR kept, only CLAUDE_ACCOUNT removed.
    [ "${lines[1]}" = "MOCK cfg=$TEST_TMP/external-cfg acct= args=" ]
}

@test "priority 4: the directory marker beats default" {
    make_account work
    claude-account bind work > /dev/null
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "priority 5: default runs with both variables removed" {
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg= acct= args=" ]
}

@test "explicit --account default strips both variables for the child" {
    make_account work
    claude-account use work > /dev/null
    run claude --account default
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg= acct= args=" ]
}

@test "wrapper invocation does not leak the env pair into the calling shell" {
    make_account work
    claude --account work > /dev/null
    [ -z "${CLAUDE_ACCOUNT-}" ]
    [ -z "${CLAUDE_CONFIG_DIR-}" ]
}

# ----------------------------------------------------------------------------
# Wrapper prefix parsing (--account/-a only before the first positional)
# ----------------------------------------------------------------------------

@test "wrapper accepts --account <name> before positionals" {
    make_account work
    run claude --account work foo bar
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=foo bar" ]
}

@test "wrapper accepts -a <name> before positionals" {
    make_account work
    run claude -a work foo
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=foo" ]
}

@test "wrapper accepts --account=<name>" {
    make_account work
    run claude --account=work
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "--account= with an empty value fails with exit 1" {
    run claude --account=
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: usage: claude --account=<name> (the value is empty). Available: default"* ]]
}

@test "--account without a value fails with exit 1" {
    run claude --account
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: usage: claude --account <name>. Available: default"* ]]
}

@test "-a after the first positional is passed through untouched" {
    make_account work
    run claude doctor -a work
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg= acct= args=doctor -a work" ]
    # No warning either: only --account/--account=* in the tail warns.
    [ "${#lines[@]}" -eq 1 ]
}

@test "claude mcp add x -- cmd -a token keeps its -a intact" {
    make_account work
    run claude mcp add x -- cmd -a token
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg= acct= args=mcp add x -- cmd -a token" ]
}

@test "--account after the first positional warns and is passed through" {
    make_account work
    run claude foo --account work
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"claude-accounts: found '--account' after the first positional argument"* ]]
    [[ "${lines[0]}" == *"Passing it through to claude uninterpreted."* ]]
    [ "${lines[1]}" = "MOCK cfg= acct= args=foo --account work" ]
}

@test "--account with an unknown name fails with exit 1" {
    run claude --account nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'nope' does not exist. Available: default"* ]]
    [[ "$output" == *"Create it with: claude-account add nope"* ]]
}

@test "--account overriding a directory binding warns and proceeds" {
    make_account work
    make_account personal
    claude-account bind work > /dev/null
    run claude --account personal
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"claude-accounts: this directory is bound to 'work' ($WORK_DIR/.claude-account), but you asked for '--account personal'. Proceeding with 'personal'."* ]]
    [ "${lines[1]}" = "MOCK cfg=$PROFILES/personal acct=personal args=" ]
}

# ----------------------------------------------------------------------------
# Exit codes
# ----------------------------------------------------------------------------

@test "wrapper propagates the child's exit code (MOCK_EXIT=7)" {
    make_account work
    export MOCK_EXIT=7
    run claude --account work
    [ "$status" -eq 7 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]

    unset MOCK_EXIT
    run claude --account work
    [ "$status" -eq 0 ]
}

# ----------------------------------------------------------------------------
# bind / unbind / current
# ----------------------------------------------------------------------------

@test "bind writes the marker and resolution follows it" {
    make_account work
    run claude-account bind work
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Directory bound to account 'work' ($WORK_DIR/.claude-account)." ]
    [ "${lines[1]}" = "Run it at the repository root so it applies to all subdirectories. Commitable, like an .nvmrc." ]
    [ -f "$WORK_DIR/.claude-account" ]
    [ "$(cat "$WORK_DIR/.claude-account")" = "work" ]

    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "bind with an unknown account fails" {
    run claude-account bind nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'nope' does not exist. Create it first with: claude-account add nope"* ]]
    [ ! -f "$WORK_DIR/.claude-account" ]
}

@test "bind without a name prints usage and fails" {
    run claude-account bind
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: claude-account bind <name>   (creates .claude-account in the current directory)"* ]]
}

@test "unbind removes the marker and is a no-op without one" {
    make_account work
    claude-account bind work > /dev/null
    run claude-account unbind
    [ "$status" -eq 0 ]
    [ "$output" = "Binding removed ($WORK_DIR/.claude-account)." ]
    [ ! -f "$WORK_DIR/.claude-account" ]

    run claude-account unbind
    [ "$status" -eq 0 ]
    [ "$output" = "No .claude-account file in this directory." ]
}

@test "current reports default when nothing is configured" {
    run claude-account current
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Account   : default" ]
    [ "${lines[1]}" = "Login     : (no login)" ]
    [ "${lines[2]}" = "Directory : $CLAUDE_ACCOUNTS_DEFAULT_DIR" ]
    [ "${lines[3]}" = "Source    : default (~/.claude)" ]
}

@test "current reflects use and shows the login email" {
    make_account work
    printf '%s\n' '{"oauthAccount":{"emailAddress":"work@example.com"}}' > "$PROFILES/work/.claude.json"
    claude-account use work > /dev/null
    run claude-account current
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Account   : work" ]
    [ "${lines[1]}" = "Login     : work@example.com" ]
    [ "${lines[2]}" = "Directory : $PROFILES/work" ]
    [ "${lines[3]}" = "Source    : claude-account use (this terminal)" ]
}

@test "current shows a directory marker as the source" {
    make_account work
    claude-account bind work > /dev/null
    run claude-account current
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Account   : work" ]
    [ "${lines[3]}" = "Source    : file $WORK_DIR/.claude-account" ]
}

@test "current reports an external CLAUDE_CONFIG_DIR as (external)" {
    export CLAUDE_CONFIG_DIR="$TEST_TMP/external-cfg"
    run claude-account current
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "Account   : (external)" ]
    [ "${lines[2]}" = "Directory : $TEST_TMP/external-cfg" ]
    [ "${lines[3]}" = "Source    : pre-existing CLAUDE_CONFIG_DIR in the environment" ]
}

# ----------------------------------------------------------------------------
# Marker walking (.claude-account up the directory tree)
# ----------------------------------------------------------------------------

@test "a marker in a parent directory applies to subdirectories" {
    make_account work
    claude-account bind work > /dev/null
    mkdir -p "$WORK_DIR/sub/inner"
    cd "$WORK_DIR/sub/inner"
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "an empty marker stops the upward walk" {
    make_account work
    claude-account bind work > /dev/null
    mkdir -p "$WORK_DIR/sub"
    : > "$WORK_DIR/sub/.claude-account"
    cd "$WORK_DIR/sub"
    run claude
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "claude-accounts: $WORK_DIR/sub/.claude-account is empty"* ]]
    [[ "${lines[0]}" == *"account binding ignored (delete it or run: claude-account bind <name>)."* ]]
    # The parent binding must NOT leak down: falls back to default.
    [ "${lines[1]}" = "MOCK cfg= acct= args=" ]
}

@test "a marker with CRLF line endings is trimmed" {
    make_account work
    printf 'work\r\n' > "$WORK_DIR/.claude-account"
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "a marker naming an unknown account warns and falls back to default" {
    printf 'ghost\n' > "$WORK_DIR/.claude-account"
    run claude
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"claude-accounts: $WORK_DIR/.claude-account points to unknown account 'ghost'. Create it with: claude-account add ghost"* ]]
    [ "${lines[1]}" = "MOCK cfg= acct= args=" ]
}

# ----------------------------------------------------------------------------
# claude-account use / use default
# ----------------------------------------------------------------------------

@test "use pins the account for this terminal and the wrapper honors it" {
    make_account work
    run claude-account use work
    [ "$status" -eq 0 ]
    [ "$output" = "This terminal now uses account 'work'. (This session only.)" ]

    # `run` is a subshell; pin for real and verify env + wrapper.
    claude-account use work > /dev/null
    [ "${CLAUDE_ACCOUNT-}" = "work" ]
    [ "${CLAUDE_CONFIG_DIR-}" = "$PROFILES/work" ]
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

@test "use default clears the pair and goes back to ~/.claude" {
    make_account work
    claude-account use work > /dev/null
    run claude-account use default
    [ "$status" -eq 0 ]
    [ "$output" = "This terminal is back on the 'default' account (~/.claude)." ]

    claude-account use default > /dev/null
    [ -z "${CLAUDE_ACCOUNT-}" ]
    [ -z "${CLAUDE_CONFIG_DIR-}" ]
    run claude
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg= acct= args=" ]
}

@test "use with an unknown account fails" {
    run claude-account use nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'nope' does not exist. Accounts: default"* ]]
}

@test "use without a name prints usage and fails" {
    run claude-account use
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage: claude-account use <name>"* ]]
}

@test "use warns when an external CLAUDE_CONFIG_DIR is involved" {
    make_account work
    export CLAUDE_CONFIG_DIR="$TEST_TMP/external-cfg"
    run claude-account use work
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-accounts: CLAUDE_CONFIG_DIR=$TEST_TMP/external-cfg was set outside this tool and will be overwritten in this session ('claude-account use default' will not restore it)."* ]]

    # Parent env still holds the external dir (run is a subshell).
    run claude-account use default
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-accounts: CLAUDE_CONFIG_DIR=$TEST_TMP/external-cfg was set outside this tool"* ]]
    [[ "$output" == *"removing it from the session; set it again manually if you need it."* ]]
}

# ----------------------------------------------------------------------------
# Residual pair (use'd account removed in another terminal)
# ----------------------------------------------------------------------------

@test "a residual use pair for a removed account is fully ignored" {
    export CLAUDE_ACCOUNT="ghost"
    export CLAUDE_CONFIG_DIR="$TEST_TMP/ghost-cfg"
    run claude
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == *"CLAUDE_ACCOUNT='ghost' does not match any registered account"* ]]
    [[ "${lines[0]}" == *"(Clear it with: claude-account use default)"* ]]
    [[ "${lines[1]}" == *"claude-accounts: also ignoring the residual CLAUDE_CONFIG_DIR ($TEST_TMP/ghost-cfg). Run: claude-account use default"* ]]
    [ "${lines[2]}" = "MOCK cfg= acct= args=" ]
}

@test "a residual pair does not block a directory marker" {
    make_account work
    claude-account bind work > /dev/null
    export CLAUDE_ACCOUNT="ghost"
    export CLAUDE_CONFIG_DIR="$TEST_TMP/ghost-cfg"
    run claude
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "MOCK cfg=$PROFILES/work acct=work args=" ]
}

# ----------------------------------------------------------------------------
# Registry semantics (.path redirects)
# ----------------------------------------------------------------------------

@test "a .path redirect wins over a directory with the same name (CRLF tolerated)" {
    mkdir -p "$PROFILES/dual"
    mkdir -p "$TEST_TMP/dual-target"
    printf '%s\r\n' "$TEST_TMP/dual-target" > "$PROFILES/dual.path"
    run claude --account dual
    [ "$status" -eq 0 ]
    # Both coexisting emits a parity warning (the .path file wins).
    [[ "$output" == *"profile 'dual' has both a directory and a .path file"* ]]
    [ "${lines[${#lines[@]}-1]}" = "MOCK cfg=$TEST_TMP/dual-target acct=dual args=" ]
}

@test "a bare tilde in a .path target expands to HOME" {
    mkdir -p "$PROFILES"
    printf '~\n' > "$PROFILES/tilde.path"
    run claude --account tilde
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$HOME acct=tilde args=" ]
}

@test "a tilde-slash .path target expands under HOME" {
    mkdir -p "$PROFILES"
    printf '~/tilde-cfg\n' > "$PROFILES/tilde.path"
    run claude --account tilde
    [ "$status" -eq 0 ]
    [ "$output" = "MOCK cfg=$HOME/tilde-cfg acct=tilde args=" ]
}

@test "an empty .path redirect makes the profile unknown" {
    mkdir -p "$PROFILES"
    : > "$PROFILES/broken.path"
    run claude --account broken
    [ "$status" -eq 1 ]
    [[ "$output" == *"claude-accounts: account 'broken' does not exist."* ]]
}

# ----------------------------------------------------------------------------
# version / help
# ----------------------------------------------------------------------------

@test "version prints the version string" {
    run claude-account version
    [ "$status" -eq 0 ]
    [ "$output" = "claude-accounts 1.0.0 (https://github.com/sppeect/claude-accounts)" ]
}

@test "help is printed when no command is given" {
    run claude-account
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude-account list"* ]]
    [[ "$output" == *"Priority: --account > use (terminal) > external CLAUDE_CONFIG_DIR > .claude-account (directory) > default"* ]]
}

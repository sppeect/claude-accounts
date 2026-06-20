# ============================================================================
# Loaded by claude-account.cmd (cmd.exe) for every subcommand except 'use'.
# Imports the module, forwards argv to `claude-account`, propagates the exit
# code. Lives in <home>\bin\; the module is one level up.
# ============================================================================
$module = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudeAccounts.psm1'
try {
    Import-Module $module -DisableNameChecking -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("claude-accounts: could not load $module - $($_.Exception.Message)")
    exit 1
}
$global:LASTEXITCODE = 0
claude-account @args
exit $LASTEXITCODE

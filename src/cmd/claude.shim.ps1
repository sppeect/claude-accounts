# ============================================================================
# Loaded by claude.cmd (cmd.exe), never sourced. Imports the module and forwards
# argv to the `claude` wrapper, then propagates the child's exit code so callers
# (and CI) see the real status. Lives in <home>\bin\; the module is one level up
# (the repo mirrors this: src\cmd\ -> src\ClaudeAccounts.psm1).
# ============================================================================
$module = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudeAccounts.psm1'
try {
    Import-Module $module -DisableNameChecking -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine("claude-accounts: could not load $module - $($_.Exception.Message)")
    exit 1
}
$global:LASTEXITCODE = 0
claude @args
exit $LASTEXITCODE

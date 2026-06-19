# ============================================================================
# Prints the config dir of a profile so claude-account.cmd's 'use' branch can
# set CLAUDE_CONFIG_DIR in the cmd session. Prints nothing and exits 1 when the
# profile is unknown. The name arrives as an argument (not interpolated into a
# command string), so it cannot inject PowerShell.
# ============================================================================
param([Parameter(Position = 0)][string]$Name)
$module = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudeAccounts.psm1'
try { Import-Module $module -DisableNameChecking -ErrorAction Stop } catch { exit 1 }
$accounts = Get-ClaudeAccounts 2>$null
if (-not $Name -or -not $accounts.Contains($Name)) { exit 1 }
[Console]::Out.Write([string]$accounts[$Name])
exit 0

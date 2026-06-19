#Requires -Version 5.1
# ============================================================================
# Smoke test for the cmd.exe shims (src/cmd/). Simulates an install (module in
# <home>, shims in <home>\bin), then drives claude.cmd / claude-account.cmd
# through a real cmd.exe session against a mock claude. Asserts that:
#   - `claude --account work` resolves via the shim and runs the MOCK (i.e. the
#     resolver skips the shim dir; no infinite recursion),
#   - `claude-account use` pins the account in the cmd session,
#   - the exit code propagates.
# Used by CI on windows-latest; runnable locally with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests/cmd-shim-smoke.ps1
# ============================================================================
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$T = Join-Path ([System.IO.Path]::GetTempPath()) ('cashim_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path "$T\home\bin", "$T\real", "$T\default" -Force | Out-Null
try {
    Copy-Item "$repo\src\ClaudeAccounts.psm1" "$T\home\ClaudeAccounts.psm1"
    Copy-Item "$repo\src\cmd\*" "$T\home\bin\"
    @(
        '@echo off'
        'echo MOCK cfg=%CLAUDE_CONFIG_DIR% acct=%CLAUDE_ACCOUNT% args=%*'
        'exit /b 0'
    ) | Set-Content "$T\real\claude.cmd" -Encoding Ascii
    New-Item -ItemType Directory -Path "$T\home\profiles\work" -Force | Out-Null

    $bat = @"
@echo off
set "PATH=$T\home\bin;$T\real;%PATH%"
set "CLAUDE_ACCOUNTS_HOME=$T\home"
set "CLAUDE_ACCOUNTS_DEFAULT_DIR=$T\default"
set "CLAUDE_ACCOUNT="
set "CLAUDE_CONFIG_DIR="
call claude --account work hello
call claude-account use work
call claude
call claude-account version
call claude --account ghost
echo GHOST_EXIT=%ERRORLEVEL%
"@
    Set-Content "$T\t.cmd" -Value $bat -Encoding Ascii
    cmd /c "`"$T\t.cmd`" > `"$T\out.txt`" 2>&1" | Out-Null
    $out = Get-Content "$T\out.txt" -Raw
    Write-Host $out

    $work = "$T\home\profiles\work"
    $checks = @(
        @{ Name = 'claude --account resolves via shim (no recursion)'; Ok = ($out -match [regex]::Escape("cfg=$work acct=work args=hello")) },
        @{ Name = 'claude-account use pins the cmd session';           Ok = ($out -match 'now uses account') },
        @{ Name = 'plain claude inherits the use-pinned account';      Ok = ($out -match [regex]::Escape("cfg=$work acct=work args=")) },
        @{ Name = 'claude-account version runs via shim';              Ok = ($out -match 'claude-accounts 1\.1\.0') },
        @{ Name = 'unknown account propagates exit code 1';            Ok = ($out -match 'GHOST_EXIT=1') }
    )
    $failed = $false
    foreach ($c in $checks) {
        if ($c.Ok) { Write-Host "  [ok] $($c.Name)" }
        else { Write-Host "  [FAIL] $($c.Name)"; $failed = $true }
    }
    if ($failed) { throw 'cmd shim smoke test FAILED' }
    Write-Host 'cmd shim smoke test: OK'
} finally {
    Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
}

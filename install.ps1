# ============================================================================
# claude-accounts installer (Windows PowerShell 5.1+ / PowerShell 7+)
# https://github.com/sppeect/claude-accounts
#
# Run it straight from GitHub:
#   iwr -useb https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.ps1 | iex
#
# What it does:
#   1. Downloads src/ClaudeAccounts.psm1 into %USERPROFILE%\.claude-accounts\
#      (saved with Invoke-WebRequest -OutFile, which writes the response bytes
#      as-is and therefore keeps the module's UTF-8 byte order mark intact -
#      Windows PowerShell 5.1 needs that BOM to parse the module correctly)
#   2. Creates %USERPROFILE%\.claude-accounts\profiles\
#   3. Adds an idempotent Import-Module block to $PROFILE.CurrentUserAllHosts,
#      delimited by '# >>> claude-accounts >>>' / '# <<< claude-accounts <<<'.
#      Piped installs (iwr | iex) never prompt; running the saved script in an
#      interactive console asks before touching the profile.
#
# Environment overrides:
#   $env:CLAUDE_ACCOUNTS_NO_RC = '1'   do not touch the PowerShell profile
#   $env:CLAUDE_ACCOUNTS_HOME          install somewhere else
#   $env:CLAUDE_ACCOUNTS_RC_FILE       write the block to this file instead
#   $env:CLAUDE_ACCOUNTS_INSTALL_REF   git ref to download from (default: main)
#   $env:CLAUDE_ACCOUNTS_INSTALL_URL   full URL of ClaudeAccounts.psm1 (tests)
#
# This file is intentionally pure ASCII (no accents, no em dashes), so it
# parses correctly under Windows PowerShell 5.1 with or without a BOM.
# ============================================================================

function Update-ClaudeAccountsProfileBlock {
    # Rewrites the managed block in a profile file: replaces the block between
    # the markers if it already exists (idempotent), appends it otherwise.
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$Block
    )
    $ErrorActionPreference = 'Stop'

    $startMarker = '# >>> claude-accounts >>>'
    $endMarker   = '# <<< claude-accounts <<<'

    $dir = Split-Path -Parent $ProfilePath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    # Detect the existing encoding by BOM so the profile is never corrupted.
    # New profiles are written as UTF-8 without BOM (the block is pure ASCII).
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $content  = ''
    if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
        $bytes = [System.IO.File]::ReadAllBytes($ProfilePath)
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $encoding = New-Object System.Text.UTF8Encoding($true)
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            $encoding = [System.Text.Encoding]::Unicode
        } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            $encoding = [System.Text.Encoding]::BigEndianUnicode
        } elseif ($bytes.Length -gt 0) {
            $encoding = [System.Text.Encoding]::Default
        }
        $content = $encoding.GetString($bytes)
        $content = $content.TrimStart([char]0xFEFF)
    }

    $pattern = '(?s)' + [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    if ($content -and [regex]::IsMatch($content, $pattern)) {
        # '$' is special in regex replacement strings - escape it as '$$'.
        $content = [regex]::Replace($content, $pattern, $Block.Replace('$', '$$'))
    } else {
        $content = $content.TrimEnd([char[]]"`r`n")
        if ($content) {
            $content = $content + "`r`n`r`n" + $Block + "`r`n"
        } else {
            $content = $Block + "`r`n"
        }
    }
    [System.IO.File]::WriteAllText($ProfilePath, $content, $encoding)
}

function Install-ClaudeAccounts {
    param([string]$ScriptPath)
    $ErrorActionPreference = 'Stop'

    $startMarker = '# >>> claude-accounts >>>'

    $ref = 'main'
    if ($env:CLAUDE_ACCOUNTS_INSTALL_REF) { $ref = $env:CLAUDE_ACCOUNTS_INSTALL_REF }
    $url = "https://raw.githubusercontent.com/sppeect/claude-accounts/$ref/src/ClaudeAccounts.psm1"
    if ($env:CLAUDE_ACCOUNTS_INSTALL_URL) { $url = $env:CLAUDE_ACCOUNTS_INSTALL_URL }

    $installDir = $env:CLAUDE_ACCOUNTS_HOME
    if (-not $installDir) { $installDir = Join-Path $env:USERPROFILE '.claude-accounts' }
    $moduleFile  = Join-Path $installDir 'ClaudeAccounts.psm1'
    $profilesDir = Join-Path $installDir 'profiles'

    Write-Host "Installing claude-accounts into $installDir ..."
    if (-not (Test-Path -LiteralPath $profilesDir)) {
        New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
    }

    # Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub requires it.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $tmp = Join-Path $installDir ("ClaudeAccounts.psm1.download." + $PID)
    try {
        # -OutFile writes the body bytes untouched, preserving the UTF-8 BOM.
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
        $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
        if (-not $raw -or $raw -notlike '*Resolve-ClaudeAccount*') {
            throw "The downloaded file does not look like ClaudeAccounts.psm1 ($url)."
        }
        Move-Item -LiteralPath $tmp -Destination $moduleFile -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    # Drop the mark-of-the-web so the profile can import the module under
    # RemoteSigned execution policy.
    try { Unblock-File -LiteralPath $moduleFile -ErrorAction SilentlyContinue } catch { }
    Write-Host "Downloaded: $moduleFile"

    # Path written inside the profile block: prefer a $env:USERPROFILE-relative
    # form so the block keeps working if the user folder ever moves.
    $blockPath = $moduleFile
    if ($blockPath.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        $blockPath = '$env:USERPROFILE' + $blockPath.Substring(($env:USERPROFILE).Length)
    }

    $blockLines = @()
    $blockLines += '# >>> claude-accounts >>>'
    $blockLines += '# Managed by the claude-accounts installer. Do not edit inside this block.'
    if ($env:CLAUDE_ACCOUNTS_HOME) {
        # A custom home only works if the module sees it at runtime too.
        $blockLines += ('$env:CLAUDE_ACCOUNTS_HOME = ' + "'" + $installDir.Replace("'", "''") + "'")
    }
    $blockLines += ('if (Test-Path "' + $blockPath + '") {')
    $blockLines += ('    Import-Module "' + $blockPath + '" -DisableNameChecking')
    $blockLines += '}'
    $blockLines += '# <<< claude-accounts <<<'
    $block = $blockLines -join "`r`n"

    $profilePath = $env:CLAUDE_ACCOUNTS_RC_FILE
    if (-not $profilePath) {
        try { $profilePath = $PROFILE.CurrentUserAllHosts } catch { }
    }
    if (-not $profilePath) {
        $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\profile.ps1'
    }

    $profileUpdated = $false
    if ($env:CLAUDE_ACCOUNTS_NO_RC -eq '1') {
        Write-Host ''
        Write-Host 'CLAUDE_ACCOUNTS_NO_RC=1 - the PowerShell profile was left untouched.'
        Write-Host 'To enable claude-accounts, add this block to your profile yourself:'
        Write-Host $block
    } else {
        $doProfile = $true
        $interactive = $false
        if ($ScriptPath) {
            try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
        }
        if ($interactive) {
            $answer = Read-Host "Add the Import-Module block to your PowerShell profile ($profilePath)? [Y/n]"
            if ($answer -match '^\s*[nN]') { $doProfile = $false }
        } else {
            Write-Host "Updating PowerShell profile: $profilePath"
            Write-Host '(set $env:CLAUDE_ACCOUNTS_NO_RC = ''1'' before running to skip this step)'
        }
        if ($doProfile) {
            Update-ClaudeAccountsProfileBlock -ProfilePath $profilePath -Block $block
            $profileUpdated = $true
            Write-Host "Profile updated: $profilePath (managed block between the claude-accounts markers)"
        } else {
            Write-Host 'Skipped. To enable claude-accounts later, add this block to your profile:'
            Write-Host $block
        }
    }

    try {
        $policy = Get-ExecutionPolicy
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
            Write-Host ''
            Write-Host "Note: your execution policy is '$policy', so the profile and the module may not load."
            Write-Host 'Allow local scripts with: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
        }
    } catch { }

    Write-Host ''
    Write-Host 'claude-accounts installed.' -ForegroundColor Green
    Write-Host "  Module   : $moduleFile"
    Write-Host "  Profiles : $profilesDir"
    Write-Host ''
    Write-Host 'Next steps:'
    if ($profileUpdated) {
        Write-Host '  1. Open a new PowerShell, or reload now:  . $PROFILE.CurrentUserAllHosts'
    } else {
        Write-Host "  1. Load it in this session:               Import-Module `"$moduleFile`" -DisableNameChecking"
    }
    Write-Host '  2. Create an account:                     claude-account add work'
    Write-Host '  3. Run Claude Code with it:               claude --account work'
    Write-Host '  4. Pin it to a project directory:         claude-account bind work'
    Write-Host '  5. See all commands:                      claude-account help'
}

$caScriptPath = $null
try { $caScriptPath = $PSCommandPath } catch { }
try {
    Install-ClaudeAccounts -ScriptPath $caScriptPath
} finally {
    Remove-Item -LiteralPath 'function:\Install-ClaudeAccounts', 'function:\Update-ClaudeAccountsProfileBlock' -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name caScriptPath -ErrorAction SilentlyContinue
}

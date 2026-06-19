# ============================================================================
# claude-accounts installer (Windows PowerShell 5.1+ / PowerShell 7+)
# https://github.com/sppeect/claude-accounts
#
# Run it straight from GitHub:
#   iwr -useb https://raw.githubusercontent.com/sppeect/claude-accounts/main/install.ps1 | iex
#
# This is the universal Windows installer: it wires up the wrapper for ALL
# Windows shells, so `claude --account <name>` works the same in PowerShell,
# Command Prompt (cmd) and Git Bash.
#
# What it does:
#   1. Installs the module + cmd shims under %USERPROFILE%\.claude-accounts\
#        - ClaudeAccounts.psm1            (PowerShell)
#        - bin\claude.cmd, bin\claude-account.cmd (+ .ps1 helpers)  (cmd.exe)
#        - claude-accounts.sh             (Git Bash / MSYS)
#   2. Creates %USERPROFILE%\.claude-accounts\profiles\
#   3. PowerShell: adds an idempotent Import-Module block to
#      $PROFILE.CurrentUserAllHosts.
#   4. cmd.exe: prepends the bin\ shim dir to your User PATH (so `claude` in cmd
#      hits the wrapper before claude.exe).
#   5. Git Bash: writes an idempotent source block to %USERPROFILE%\.bashrc.
#   Each block is delimited by '# >>> claude-accounts >>>' / '# <<< ... <<<'.
#   Piped installs (iwr | iex) never prompt; running the saved script in an
#   interactive console asks before touching your profiles.
#
# Environment overrides:
#   $env:CLAUDE_ACCOUNTS_NO_RC   = '1'   do not touch any shell profile/rc
#   $env:CLAUDE_ACCOUNTS_NO_PATH = '1'   do not modify the User PATH
#   $env:CLAUDE_ACCOUNTS_NO_BASH = '1'   do not touch ~/.bashrc (Git Bash)
#   $env:CLAUDE_ACCOUNTS_HOME            install somewhere else
#   $env:CLAUDE_ACCOUNTS_RC_FILE         write the PowerShell block to this file
#   $env:CLAUDE_ACCOUNTS_INSTALL_REF     git ref to download from (default: main)
#   $env:CLAUDE_ACCOUNTS_INSTALL_BASE    base raw URL (advanced / mirrors)
#   $env:CLAUDE_ACCOUNTS_INSTALL_URL     full URL of ClaudeAccounts.psm1 (legacy)
#
# This file is intentionally pure ASCII (no accents, no em dashes), so it
# parses correctly under Windows PowerShell 5.1 with or without a BOM.
# ============================================================================

$startMarker = '# >>> claude-accounts >>>'
$endMarker   = '# <<< claude-accounts <<<'

function Update-ClaudeAccountsProfileBlock {
    # Rewrites the managed block in a profile file: replaces the block between
    # the markers if it already exists (idempotent), appends it otherwise.
    param(
        [Parameter(Mandatory = $true)][string]$ProfilePath,
        [Parameter(Mandatory = $true)][string]$Block
    )
    $ErrorActionPreference = 'Stop'

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

function Update-ClaudeAccountsBashBlock {
    # Writes the managed source block into a bash rc file (Git Bash ~/.bashrc).
    # Uses LF line endings and UTF-8 without BOM so bash parses it correctly,
    # and is idempotent (replaces an existing block between the markers).
    param(
        [Parameter(Mandatory = $true)][string]$RcPath,
        [Parameter(Mandatory = $true)][string]$Block
    )
    $ErrorActionPreference = 'Stop'
    $content = ''
    if (Test-Path -LiteralPath $RcPath -PathType Leaf) {
        $content = [System.IO.File]::ReadAllText($RcPath)
        $content = $content.TrimStart([char]0xFEFF)
    }
    $pattern = '(?s)' + [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
    if ($content -and [regex]::IsMatch($content, $pattern)) {
        $content = [regex]::Replace($content, $pattern, $Block.Replace('$', '$$'))
    } else {
        $content = $content -replace "(`r?`n)+$", ''
        if ($content) { $content = $content + "`n`n" + $Block + "`n" }
        else { $content = $Block + "`n" }
    }
    $content = $content -replace "`r`n", "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($RcPath, $content, $utf8NoBom)
}

function Add-ClaudeAccountsToUserPath {
    # Prepends $Dir to the User PATH, preserving the registry value kind so an
    # existing REG_EXPAND_SZ PATH (with %VARS%) is not flattened. Idempotent.
    # Returns $true if the PATH was changed.
    param([Parameter(Mandatory = $true)][string]$Dir)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $key) { $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') }
    try {
        $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString
        $cur  = ''
        try {
            $cur  = [string]$key.GetValue('PATH', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = $key.GetValueKind('PATH')
        } catch { }
        $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
        foreach ($p in $parts) {
            if ($p.TrimEnd('\', '/') -ieq $Dir.TrimEnd('\', '/')) { return $false }
        }
        $new = (@($Dir) + $parts) -join ';'
        $key.SetValue('PATH', $new, $kind)
        return $true
    } finally { $key.Close() }
}

function Install-ClaudeAccounts {
    param([string]$ScriptPath)
    $ErrorActionPreference = 'Stop'

    $ref = 'main'
    if ($env:CLAUDE_ACCOUNTS_INSTALL_REF) { $ref = $env:CLAUDE_ACCOUNTS_INSTALL_REF }
    $script:BaseUrl = "https://raw.githubusercontent.com/sppeect/claude-accounts/$ref"
    if ($env:CLAUDE_ACCOUNTS_INSTALL_BASE) { $script:BaseUrl = $env:CLAUDE_ACCOUNTS_INSTALL_BASE.TrimEnd('/') }
    # Legacy single-URL override: derive the base from it when it points at the module.
    if ($env:CLAUDE_ACCOUNTS_INSTALL_URL -and $env:CLAUDE_ACCOUNTS_INSTALL_URL -match '^(.*)/src/ClaudeAccounts\.psm1/?$') {
        $script:BaseUrl = $Matches[1]
    }

    # Local install: when run from a clone (src\ next to this script), copy from
    # disk instead of downloading. iwr|iex has no $PSScriptRoot, so it downloads.
    $script:LocalRoot = $null
    if ($PSScriptRoot -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'src\ClaudeAccounts.psm1'))) {
        $script:LocalRoot = $PSScriptRoot
    }

    $installDir  = $env:CLAUDE_ACCOUNTS_HOME
    if (-not $installDir) { $installDir = Join-Path $env:USERPROFILE '.claude-accounts' }
    $binDir      = Join-Path $installDir 'bin'
    $profilesDir = Join-Path $installDir 'profiles'
    $moduleFile  = Join-Path $installDir 'ClaudeAccounts.psm1'

    Write-Host "Installing claude-accounts into $installDir ..."
    foreach ($d in @($installDir, $binDir, $profilesDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    # Windows PowerShell 5.1 may not offer TLS 1.2 by default; GitHub requires it.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    # ---- payload: relative source path -> destination -----------------------
    $files = @(
        @{ Rel = 'src/ClaudeAccounts.psm1';            Dest = $moduleFile;                                  Check = 'Resolve-ClaudeAccount' },
        @{ Rel = 'src/cmd/claude.cmd';                 Dest = (Join-Path $binDir 'claude.cmd');             Check = $null },
        @{ Rel = 'src/cmd/claude.shim.ps1';            Dest = (Join-Path $binDir 'claude.shim.ps1');        Check = $null },
        @{ Rel = 'src/cmd/claude-account.cmd';         Dest = (Join-Path $binDir 'claude-account.cmd');     Check = $null },
        @{ Rel = 'src/cmd/claude-account.shim.ps1';    Dest = (Join-Path $binDir 'claude-account.shim.ps1');Check = $null },
        @{ Rel = 'src/cmd/claude-account-usedir.ps1';  Dest = (Join-Path $binDir 'claude-account-usedir.ps1'); Check = $null },
        @{ Rel = 'src/claude-accounts.sh';             Dest = (Join-Path $installDir 'claude-accounts.sh'); Check = '_ca_resolve' }
    )
    foreach ($f in $files) { Get-ClaudeAccountsFile -RelPath $f.Rel -Dest $f.Dest -MustContain $f.Check }

    # Drop the mark-of-the-web so the profile can import the module / run the
    # shims under RemoteSigned execution policy.
    foreach ($f in $files) {
        try { Unblock-File -LiteralPath $f.Dest -ErrorAction SilentlyContinue } catch { }
    }
    Write-Host "Installed module + cmd shims under $installDir"

    # =====================================================================
    # 1) PowerShell profile
    # =====================================================================
    $blockPath = $moduleFile
    if ($blockPath.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
        $blockPath = '$env:USERPROFILE' + $blockPath.Substring(($env:USERPROFILE).Length)
    }
    $blockLines = @()
    $blockLines += $startMarker
    $blockLines += '# Managed by the claude-accounts installer. Do not edit inside this block.'
    if ($env:CLAUDE_ACCOUNTS_HOME) {
        $blockLines += ('$env:CLAUDE_ACCOUNTS_HOME = ' + "'" + $installDir.Replace("'", "''") + "'")
    }
    $blockLines += ('if (Test-Path "' + $blockPath + '") {')
    $blockLines += ('    Import-Module "' + $blockPath + '" -DisableNameChecking')
    $blockLines += '}'
    $blockLines += $endMarker
    $block = $blockLines -join "`r`n"

    $profilePath = $env:CLAUDE_ACCOUNTS_RC_FILE
    if (-not $profilePath) {
        try { $profilePath = $PROFILE.CurrentUserAllHosts } catch { }
    }
    if (-not $profilePath) {
        $profilePath = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\profile.ps1'
    }

    $interactive = $false
    if ($ScriptPath) {
        try { $interactive = -not [Console]::IsInputRedirected } catch { $interactive = $false }
    }

    $profileUpdated = $false
    if ($env:CLAUDE_ACCOUNTS_NO_RC -eq '1') {
        Write-Host ''
        Write-Host 'CLAUDE_ACCOUNTS_NO_RC=1 - shell profiles/rc were left untouched.'
    } else {
        $doProfile = $true
        if ($interactive) {
            $answer = Read-Host "Add the Import-Module block to your PowerShell profile ($profilePath)? [Y/n]"
            if ($answer -match '^\s*[nN]') { $doProfile = $false }
        }
        if ($doProfile) {
            Update-ClaudeAccountsProfileBlock -ProfilePath $profilePath -Block $block
            $profileUpdated = $true
            Write-Host "PowerShell profile updated: $profilePath"
        } else {
            Write-Host 'Skipped the PowerShell profile.'
        }

        # =================================================================
        # 3) Git Bash ~/.bashrc
        # =================================================================
        if ($env:CLAUDE_ACCOUNTS_NO_BASH -ne '1') {
            $shText = $installDir
            if ($shText.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase)) {
                $shText = '$HOME' + $installDir.Substring(($env:USERPROFILE).Length)
            }
            $shText = ($shText -replace '\\', '/') + '/claude-accounts.sh'
            $bashBlock = @(
                $startMarker,
                '# Managed by the claude-accounts installer. Do not edit inside this block.',
                ('[ -f "' + $shText + '" ] && . "' + $shText + '"'),
                $endMarker
            ) -join "`n"
            $bashrc = Join-Path $env:USERPROFILE '.bashrc'
            $doBash = $true
            if ($interactive) {
                $answer = Read-Host "Add the source block to Git Bash ($bashrc)? [Y/n]"
                if ($answer -match '^\s*[nN]') { $doBash = $false }
            }
            if ($doBash) {
                Update-ClaudeAccountsBashBlock -RcPath $bashrc -Block $bashBlock
                Write-Host "Git Bash rc updated: $bashrc"
            } else {
                Write-Host 'Skipped Git Bash ~/.bashrc.'
            }
        }
    }

    # =====================================================================
    # 2) cmd.exe: put the shim dir first on the User PATH
    # =====================================================================
    if ($env:CLAUDE_ACCOUNTS_NO_PATH -eq '1') {
        Write-Host 'CLAUDE_ACCOUNTS_NO_PATH=1 - the User PATH was left untouched.'
        Write-Host "For cmd support, add this directory to the front of your PATH: $binDir"
    } else {
        $changed = $false
        try { $changed = Add-ClaudeAccountsToUserPath -Dir $binDir } catch {
            Write-Host "Could not update the User PATH automatically: $($_.Exception.Message)"
            Write-Host "Add this directory to the front of your PATH manually: $binDir"
        }
        if ($changed) { Write-Host "User PATH updated (cmd shims): $binDir" }
        else { Write-Host "User PATH already contains the shim dir: $binDir" }
        # Make it usable in THIS session too.
        if ((($env:PATH -split ';') | Where-Object { $_.TrimEnd('\', '/') -ieq $binDir.TrimEnd('\', '/') }).Count -eq 0) {
            $env:PATH = $binDir + ';' + $env:PATH
        }
    }

    try {
        $policy = Get-ExecutionPolicy
        if ($policy -eq 'Restricted' -or $policy -eq 'AllSigned') {
            Write-Host ''
            Write-Host "Note: your execution policy is '$policy', so the profile, module and shims may not load."
            Write-Host 'Allow local scripts with: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
        }
    } catch { }

    Write-Host ''
    Write-Host 'claude-accounts installed (PowerShell + cmd + Git Bash).' -ForegroundColor Green
    Write-Host "  Module   : $moduleFile"
    Write-Host "  Cmd shims: $binDir"
    Write-Host "  Bash      : $(Join-Path $installDir 'claude-accounts.sh')"
    Write-Host "  Profiles : $profilesDir"
    Write-Host ''
    Write-Host 'Next steps:'
    if ($profileUpdated) {
        Write-Host '  1. Open a NEW terminal (PowerShell, cmd or Git Bash), or in PowerShell reload now:'
        Write-Host '       . $PROFILE.CurrentUserAllHosts'
    } else {
        Write-Host "  1. Load it in this session:  Import-Module `"$moduleFile`" -DisableNameChecking"
    }
    Write-Host '  2. Create an account:        claude-account add work'
    Write-Host '  3. Run Claude Code with it:  claude --account work'
    Write-Host '  4. Check the install:        claude-account doctor'
}

function Get-ClaudeAccountsFile {
    # Copies a payload file from the local clone when available, otherwise
    # downloads it from $script:BaseUrl. Optionally verifies a marker string.
    param(
        [Parameter(Mandatory = $true)][string]$RelPath,
        [Parameter(Mandatory = $true)][string]$Dest,
        [string]$MustContain
    )
    $ErrorActionPreference = 'Stop'
    $destDir = Split-Path -Parent $Dest
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    if ($script:LocalRoot) {
        $local = Join-Path $script:LocalRoot ($RelPath -replace '/', '\')
        if (Test-Path -LiteralPath $local) {
            Copy-Item -LiteralPath $local -Destination $Dest -Force
            if ($MustContain) {
                $raw = Get-Content -LiteralPath $Dest -Raw -Encoding UTF8
                if (-not $raw -or $raw -notlike "*$MustContain*") { throw "Local file $local does not look right (missing '$MustContain')." }
            }
            return
        }
    }

    $url = "$script:BaseUrl/$RelPath"
    $tmp = "$Dest.download.$PID"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
        if ($MustContain) {
            $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
            if (-not $raw -or $raw -notlike "*$MustContain*") { throw "Downloaded file does not look right ($url)." }
        }
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

$caScriptPath = $null
try { $caScriptPath = $PSCommandPath } catch { }
try {
    Install-ClaudeAccounts -ScriptPath $caScriptPath
} finally {
    Remove-Item -LiteralPath `
        'function:\Install-ClaudeAccounts', `
        'function:\Update-ClaudeAccountsProfileBlock', `
        'function:\Update-ClaudeAccountsBashBlock', `
        'function:\Add-ClaudeAccountsToUserPath', `
        'function:\Get-ClaudeAccountsFile' -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name caScriptPath -ErrorAction SilentlyContinue
}

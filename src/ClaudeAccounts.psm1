# ============================================================================
# claude-accounts — multi-account manager for Claude Code (AWS CLI profile style)
# https://github.com/sppeect/claude-accounts          (Windows PowerShell 5.1+)
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
#   1. --account / -a flag           (accepted only BEFORE the first positional
#                                     argument, e.g.: claude --account work -p "...")
#   2. $env:CLAUDE_ACCOUNT           (set by `claude-account use`)
#   3. $env:CLAUDE_CONFIG_DIR        (set externally — same contract as the bare exe)
#   4. .claude-account file          (searched from the current directory upward)
#   5. default                       (~\.claude — the original installation)
#
# Registry: a profile named <name> is either a directory
# $CLAUDE_ACCOUNTS_HOME\profiles\<name>\ (the directory IS the config dir) or
# a file profiles\<name>.path whose first line points to a custom config dir.
#
# Notes for scripts: check $LASTEXITCODE (preserved), not $? (a wrapper
# function cannot propagate $? from a native exe in PowerShell 5.1).
# Processes spawned outside PowerShell (npm scripts, git hooks, Start-Process)
# bypass the wrapper — run `claude-account use <name>` first, which exports
# CLAUDE_CONFIG_DIR persistently in the session and is inherited by children.
# ============================================================================

$script:Version = '1.1.0'

function Get-ClaudeAccountsHome {
    if ($env:CLAUDE_ACCOUNTS_HOME) { return $env:CLAUDE_ACCOUNTS_HOME }
    return (Join-Path $env:USERPROFILE '.claude-accounts')
}

function Get-ClaudeDefaultDir {
    if ($env:CLAUDE_ACCOUNTS_DEFAULT_DIR) { return $env:CLAUDE_ACCOUNTS_DEFAULT_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
}

function Get-ClaudeShimDir {
    # Directory that holds the cmd shims (claude.cmd / claude-account.cmd). They
    # delegate back into this module, so the executable resolver must never pick
    # a 'claude' found here or it would invoke itself forever.
    return (Join-Path (Get-ClaudeAccountsHome) 'bin')
}

$script:MarkerFileName = '.claude-account'

# What a profile inherits from another config dir on `add` / `migrate`.
# Strict allow-list: configuration, tooling and usage content travel; identity
# and ephemeral state never do, so every profile keeps its own login and caches.
# Deliberately excluded: .credentials.json and .claude.json (login/identity),
# *.bak/backups, statsig, ide, daemon, shell-snapshots and the *-cache entries.
$script:InheritItems = @(
    'settings.json', 'keybindings.json', 'CLAUDE.md',
    'skills', 'agents', 'commands', 'plugins', 'rules', 'output-styles', 'themes', 'hooks',
    'projects', 'todos', 'sessions', 'history.jsonl'
)

function Copy-ClaudeProfileContent {
    <# Copies the allow-listed configuration/tooling/usage content from a source
       config dir into a destination profile dir. Existing entries in the
       destination are never overwritten. Returns the list of items copied. #>
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$Items = $script:InheritItems
    )
    $copied = @()
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return $copied }
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    foreach ($item in $Items) {
        $src = Join-Path $Source $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $Destination $item
        if (Test-Path -LiteralPath $dst) { continue }   # never clobber the profile's own data
        try {
            Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop
            $copied += $item
        } catch {
            Write-Warning "Could not copy '$item' from '$Source': $($_.Exception.Message)"
        }
    }
    return $copied
}

function Get-ClaudeAccounts {
    <# Returns an ordered dictionary name -> config directory.
       'default' (~\.claude) always exists and lives outside the registry.
       The registry is the filesystem: profiles\<name>\ directories and
       profiles\<name>.path redirect files.
       (The case-insensitive comparer of [ordered]@{} is intentional on Windows.) #>
    $map = [ordered]@{ 'default' = (Get-ClaudeDefaultDir) }
    $profilesRoot = Join-Path (Get-ClaudeAccountsHome) 'profiles'
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) { return $map }

    foreach ($entry in (Get-ChildItem -LiteralPath $profilesRoot -Force | Sort-Object Name)) {
        if ($entry.PSIsContainer) {
            if ($entry.Name -eq 'default') {
                Write-Warning "Profile directory 'default' is reserved and was ignored ($($entry.FullName))."
                continue
            }
            if (-not $map.Contains($entry.Name)) { $map[$entry.Name] = $entry.FullName }
        } elseif ($entry.Name -like '*.path') {
            $name = $entry.Name.Substring(0, $entry.Name.Length - 5)
            if (-not $name -or $name -eq 'default') { continue }
            $target = $null
            try { $target = (Get-Content -LiteralPath $entry.FullName -TotalCount 1 -Encoding UTF8 | Select-Object -First 1) } catch {}
            if ($target) { $target = ([string]$target).Trim() }
            if (-not $target) {
                Write-Warning "Redirect file $($entry.FullName) is empty — profile '$name' ignored."
                continue
            }
            if ($target -eq '~') { $target = $env:USERPROFILE }
            elseif ($target -like '~\*' -or $target -like '~/*') { $target = Join-Path $env:USERPROFILE $target.Substring(2) }
            if ($map.Contains($name) -and $name -ne 'default') {
                Write-Warning "Profile '$name' has both a directory and a .path file — the .path file wins."
            }
            $map[$name] = $target
        }
    }
    return $map
}

function Find-ClaudeAccountMarker {
    <# Searches for a .claude-account file from the current directory upward
       (like .nvmrc). The first marker found decides — an empty marker stops
       the walk (a parent directory's binding must not silently leak down).
       Returns @{ Name; File } or $null. #>
    try {
        $dir = (Get-Location).ProviderPath
        if (-not (Test-Path -LiteralPath $dir)) { return $null }
    } catch { return $null }
    while ($dir) {
        $file = Join-Path $dir $script:MarkerFileName
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $name = $null
            try { $name = (Get-Content -LiteralPath $file -TotalCount 1 -Encoding UTF8 | Select-Object -First 1) } catch {}
            if ($name) { $name = ([string]$name).Trim() }
            if ($name) { return @{ Name = $name; File = $file } }
            Write-Warning "File $file is empty — account binding ignored (delete it or run: claude-account bind <name>)."
            return $null
        }
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Resolve-ClaudeAccount {
    <# Decides which account to use. Returns an object with Name, Dir, Source.
       Dir = $null means "use the default ~\.claude" (env is cleared during
       the invocation). #>
    param([string]$Explicit)

    $accounts = Get-ClaudeAccounts

    if ($Explicit) {
        if (-not $accounts.Contains($Explicit)) {
            throw "Account '$Explicit' does not exist. Available accounts: $($accounts.Keys -join ', '). Create it with: claude-account add $Explicit"
        }
        $marker = Find-ClaudeAccountMarker
        if ($marker -and $marker.Name -ne $Explicit) {
            Write-Warning "This directory is bound to account '$($marker.Name)' ($($marker.File)), but you asked for '--account $Explicit'. Proceeding with '$Explicit'."
        }
        $dir = $null
        if ($Explicit -ne 'default') { $dir = $accounts[$Explicit] }
        return [pscustomobject]@{ Name = $Explicit; Dir = $dir; Source = '--account flag' }
    }

    $envAccountInvalid = $false
    if ($env:CLAUDE_ACCOUNT) {
        $name = $env:CLAUDE_ACCOUNT.Trim()
        if ($accounts.Contains($name)) {
            $dir = $null
            if ($name -ne 'default') { $dir = $accounts[$name] }
            return [pscustomobject]@{ Name = $name; Dir = $dir; Source = 'claude-account use (this terminal)' }
        }
        $envAccountInvalid = $true
        Write-Warning "CLAUDE_ACCOUNT='$name' does not match any registered account — ignoring. (Clear it with: claude-account use default)"
    }

    if ($env:CLAUDE_CONFIG_DIR) {
        if ($envAccountInvalid) {
            # Residual pair from a `claude-account use` for an account that no
            # longer exists — using this CLAUDE_CONFIG_DIR would run the
            # removed account.
            Write-Warning "Also ignoring the residual CLAUDE_CONFIG_DIR ($env:CLAUDE_CONFIG_DIR). Run: claude-account use default"
        } else {
            $marker = Find-ClaudeAccountMarker
            if ($marker) {
                Write-Warning "CLAUDE_CONFIG_DIR is set in the environment and takes priority — this directory's binding ($($marker.File) -> '$($marker.Name)') was ignored."
            }
            return [pscustomobject]@{ Name = '(external)'; Dir = $env:CLAUDE_CONFIG_DIR; Source = 'pre-existing CLAUDE_CONFIG_DIR in the environment' }
        }
    }

    $marker = Find-ClaudeAccountMarker
    if ($marker) {
        if ($accounts.Contains($marker.Name)) {
            $dir = $null
            if ($marker.Name -ne 'default') { $dir = $accounts[$marker.Name] }
            return [pscustomobject]@{ Name = $marker.Name; Dir = $dir; Source = "file $($marker.File)" }
        }
        Write-Warning "File $($marker.File) points to unknown account '$($marker.Name)'. Create it with: claude-account add $($marker.Name)"
    }

    return [pscustomobject]@{ Name = 'default'; Dir = $null; Source = 'default (~\.claude)' }
}

function Get-ClaudeAccountEmail {
    <# Reads the logged-in email from a config dir's .claude.json, if any. #>
    param([string]$Dir)
    if (-not $Dir) { return $null }
    $stateFile = Join-Path $Dir '.claude.json'
    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) { return $null }
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.oauthAccount -and $state.oauthAccount.emailAddress) {
            return [string]$state.oauthAccount.emailAddress
        }
    } catch {}
    return $null
}

function Get-ClaudeExecutable {
    # Resolve the real claude binary, skipping our own cmd shim. The shim dir is
    # first on PATH (so `claude` in cmd hits the wrapper), which means
    # Get-Command would otherwise return claude.cmd and the wrapper would call
    # itself. Walk every candidate and take the first one outside the shim dir.
    $shimDir = (Get-ClaudeShimDir).TrimEnd('\', '/')
    foreach ($cmd in (Get-Command 'claude' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $src = $cmd.Source
        if (-not $src) { continue }
        $parent = (Split-Path -Parent $src)
        if ($parent) { $parent = $parent.TrimEnd('\', '/') }
        if ($parent -and $parent -ieq $shimDir) { continue }   # never resolve to our own shim
        return $src
    }
    $fallback = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    return $null
}

function Invoke-ClaudeWithConfigDir {
    <# Runs an executable with CLAUDE_CONFIG_DIR and CLAUDE_ACCOUNT adjusted
       only for the duration of the call (the snapshot inherited by the child
       remains valid for the process lifetime, including hooks and MCP servers
       it spawns). CLAUDE_ACCOUNT is also managed so that nested invocations
       (hooks calling `claude` again) resolve the SAME account. #>
    param(
        [string]$Exe,
        [object[]]$Arguments,
        [pscustomobject]$Account,
        [bool]$HasPipelineInput,
        [object]$PipelineInput
    )
    if ($Account.Name -ne 'default' -and $Account.Name -ne '(external)' -and (-not $Account.Dir -or -not ([string]$Account.Dir).Trim())) {
        throw "Account '$($Account.Name)' resolved to an empty directory — check $(Join-Path (Get-ClaudeAccountsHome) 'profiles')."
    }
    $prevConfigDir  = $env:CLAUDE_CONFIG_DIR
    $hadConfigDir   = ($null -ne $prevConfigDir)
    $prevAccount    = $env:CLAUDE_ACCOUNT
    $hadAccount     = ($null -ne $prevAccount)
    $prevOutputEnc  = $null
    try {
        if ($Account.Name -eq 'default') {
            Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
            Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
        } elseif ($Account.Name -eq '(external)') {
            Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
        } else {
            $env:CLAUDE_CONFIG_DIR = $Account.Dir
            $env:CLAUDE_ACCOUNT    = $Account.Name
        }
        if ($null -eq $Arguments) { $Arguments = @() }
        if ($HasPipelineInput) {
            # PS 5.1 re-encodes pipes to native exes with $OutputEncoding,
            # whose default is US-ASCII — it would corrupt non-ASCII stdin.
            $prevOutputEnc = $global:OutputEncoding
            $global:OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $PipelineInput | & $Exe @Arguments
        } else {
            & $Exe @Arguments
        }
    } finally {
        if ($null -ne $prevOutputEnc) { $global:OutputEncoding = $prevOutputEnc }
        if ($hadConfigDir) { $env:CLAUDE_CONFIG_DIR = $prevConfigDir }
        else { Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue }
        if ($hadAccount) { $env:CLAUDE_ACCOUNT = $prevAccount }
        else { Remove-Item Env:CLAUDE_ACCOUNT -ErrorAction SilentlyContinue }
    }
}

function claude {
    <# Wrapper for claude.exe with --account/-a support and automatic
       per-directory selection (.claude-account). The flag is only interpreted
       BEFORE the first positional argument — everything else is passed
       through intact, so `claude mcp add x '--' cmd -a token` never has its
       '-a' hijacked. (An unquoted `--` is consumed by PowerShell itself
       before reaching the wrapper — quote it ('--') when you need to pass it
       through to claude.) #>
    # Error paths must report message + exit code, never throw — even when the
    # caller (or a CI runner) sets a global $ErrorActionPreference = 'Stop'.
    $ErrorActionPreference = 'Continue'
    $explicit = $null
    $i = 0
    while ($i -lt $args.Count) {
        $arg = $args[$i]
        if ($arg -eq '--account' -or $arg -eq '-a') {
            if ($i + 1 -ge $args.Count) {
                $names = (Get-ClaudeAccounts).Keys -join ', '
                $global:LASTEXITCODE = 1
                Write-Error "Usage: claude --account <name>. Available accounts: $names"
                return
            }
            $explicit = [string]$args[$i + 1]
            $i += 2
        } elseif ($arg -is [string] -and $arg -like '--account=*') {
            $explicit = $arg.Substring('--account='.Length)
            if (-not $explicit) {
                $global:LASTEXITCODE = 1
                Write-Error "Usage: claude --account=<name> (the value is empty). Accounts: $((Get-ClaudeAccounts).Keys -join ', ')"
                return
            }
            $i++
        } else {
            break
        }
    }
    $rest = @()
    if ($i -lt $args.Count) { $rest = @($args[$i..($args.Count - 1)]) }

    foreach ($tail in $rest) {
        if ($tail -is [string] -and ($tail -eq '--account' -or $tail -like '--account=*')) {
            Write-Warning "Found '$tail' after the first positional argument — the account flag only applies at the start (claude --account <name> ...). Passing it through to claude.exe uninterpreted."
            break
        }
    }

    try {
        $account = Resolve-ClaudeAccount -Explicit $explicit
    } catch {
        $global:LASTEXITCODE = 1
        Write-Error $_.Exception.Message
        return
    }

    $exe = Get-ClaudeExecutable
    if (-not $exe) {
        $global:LASTEXITCODE = 1
        Write-Error 'claude.exe not found on PATH. Install Claude Code first.'
        return
    }

    Invoke-ClaudeWithConfigDir -Exe $exe -Arguments $rest -Account $account `
        -HasPipelineInput $MyInvocation.ExpectingInput -PipelineInput $input
}

function claude-account {
    <# Manages Claude Code account profiles. Run without arguments for help. #>
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            'list', 'add', 'remove', 'use', 'current', 'bind', 'unbind', 'migrate', 'doctor', 'version', 'help' | Where-Object { $_ -like "$wordToComplete*" }
        })]
        [string]$Command = 'help',

        [Parameter(Position = 1)]
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete)
            try { (Get-ClaudeAccounts).Keys | Where-Object { $_ -like "$wordToComplete*" } } catch { @() }
        })]
        [string]$Name,

        [string]$Path,
        [string]$From,
        [switch]$NoLogin,
        [switch]$Minimal,
        [switch]$Force
    )

    # Error paths must report message + exit code, never throw — even when the
    # caller (or a CI runner) sets a global $ErrorActionPreference = 'Stop'.
    $ErrorActionPreference = 'Continue'

    $profilesRoot = Join-Path (Get-ClaudeAccountsHome) 'profiles'

    switch ($Command) {

        'list' {
            $accounts = Get-ClaudeAccounts
            $active = $null
            try { $active = (Resolve-ClaudeAccount).Name } catch {}
            $rows = foreach ($key in $accounts.Keys) {
                $dir = $accounts[$key]
                $email = Get-ClaudeAccountEmail -Dir $dir
                $login = $email
                if (-not $login) {
                    if (Test-Path -LiteralPath (Join-Path $dir '.credentials.json') -PathType Leaf) {
                        $login = '(logged in)'
                    } else {
                        $login = "(no login - run: claude --account $key)"
                    }
                }
                $flag = ''
                if ($key -eq $active) { $flag = '*' }
                [pscustomobject]@{ Active = $flag; Account = $key; Login = $login; Directory = $dir }
            }
            return $rows
        }

        'add' {
            if (-not $Name) { $global:LASTEXITCODE = 1; Write-Error 'Usage: claude-account add <name> [-Path <dir>] [-NoLogin]'; return }
            if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') {
                $global:LASTEXITCODE = 1
                Write-Error "Invalid name: '$Name'. Use letters, digits, hyphen and underscore."
                return
            }
            $accounts = Get-ClaudeAccounts
            if ($accounts.Contains($Name)) {
                $global:LASTEXITCODE = 1
                Write-Error "Account '$Name' already exists ($($accounts[$Name]))."
                return
            }
            if (-not (Test-Path -LiteralPath $profilesRoot)) {
                New-Item -ItemType Directory -Path $profilesRoot -Force | Out-Null
            }
            $dir = $null
            if ($Path) {
                $expanded = $Path
                if ($expanded -eq '~') { $expanded = $env:USERPROFILE }
                elseif ($expanded -like '~\*' -or $expanded -like '~/*') { $expanded = Join-Path $env:USERPROFILE $expanded.Substring(2) }
                $dir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine((Get-Location).ProviderPath, $expanded))
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                # BOM-less so the bash implementation can read the same registry.
                [System.IO.File]::WriteAllLines((Join-Path $profilesRoot "$Name.path"), @($dir), (New-Object System.Text.UTF8Encoding($false)))
            } else {
                $dir = Join-Path $profilesRoot $Name
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }

            # Inherit from the default profile so a new account starts with the
            # same tools and preferences. -Minimal copies only settings.json;
            # the full set never includes credentials (the profile logs in on
            # its own). The login files below are why each account stays separate.
            $inherit = $script:InheritItems
            if ($Minimal) { $inherit = @('settings.json') }
            $copied = Copy-ClaudeProfileContent -Source (Get-ClaudeDefaultDir) -Destination $dir -Items $inherit

            Write-Host "Account '$Name' created at $dir" -ForegroundColor Green
            if ($copied.Count -gt 0) {
                Write-Host "Inherited from default: $($copied -join ', ')" -ForegroundColor DarkGray
            }

            if ($NoLogin) {
                Write-Host "To authenticate later: claude --account $Name  (login will be requested on first run)"
                return
            }
            Write-Host "Opening login in the browser — sign in with the claude.ai account that belongs to '$Name'." -ForegroundColor Yellow
            $exe = Get-ClaudeExecutable
            if (-not $exe) { $global:LASTEXITCODE = 1; Write-Error 'claude.exe not found on PATH.'; return }
            $account = [pscustomobject]@{ Name = $Name; Dir = $dir; Source = 'add' }
            Invoke-ClaudeWithConfigDir -Exe $exe -Arguments @('auth', 'login') -Account $account -HasPipelineInput $false -PipelineInput $null
        }

        'remove' {
            if (-not $Name) { $global:LASTEXITCODE = 1; Write-Error 'Usage: claude-account remove <name> [-Force]'; return }
            if ($Name -eq 'default') { $global:LASTEXITCODE = 1; Write-Error "The 'default' account (~\.claude) cannot be removed."; return }

            # Handle a .path redirect first (even an empty/orphaned one must be
            # deletable through the tool).
            $pathFile = Join-Path $profilesRoot "$Name.path"
            if (Test-Path -LiteralPath $pathFile -PathType Leaf) {
                $accounts = Get-ClaudeAccounts
                $dir = '(unresolved)'
                if ($accounts.Contains($Name)) { $dir = $accounts[$Name] }
                if ($env:CLAUDE_ACCOUNT -eq $Name) {
                    Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
                    Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
                    Write-Host "This terminal was using '$Name' — switched back to 'default'."
                }
                Remove-Item -LiteralPath $pathFile -Confirm:$false
                Write-Host "Account '$Name' removed (redirect file deleted; the target directory $dir was NOT touched)." -ForegroundColor Green
                return
            }

            $accounts = Get-ClaudeAccounts
            if (-not $accounts.Contains($Name)) { $global:LASTEXITCODE = 1; Write-Error "Account '$Name' does not exist."; return }

            if ($env:CLAUDE_ACCOUNT -eq $Name) {
                Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
                Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
                Write-Host "This terminal was using '$Name' — switched back to 'default'."
            }

            $profileDir = Join-Path $profilesRoot $Name
            if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
                $global:LASTEXITCODE = 1
                Write-Error "Could not locate the profile entry for '$Name' under $profilesRoot."
                return
            }
            $item = Get-Item -LiteralPath $profileDir -ErrorAction SilentlyContinue
            if ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                # Junction/symlink: removing it only deletes the link, never the
                # target's content — non-destructive, so no -Force needed.
                [System.IO.Directory]::Delete($item.FullName, $false)
                Write-Host "Link $profileDir removed (target content preserved)." -ForegroundColor Green
                return
            }
            $hasCredentials = (Test-Path -LiteralPath (Join-Path $profileDir '.credentials.json') -PathType Leaf) -or
                              (Test-Path -LiteralPath (Join-Path $profileDir '.claude.json') -PathType Leaf)
            if ($hasCredentials -and -not $Force) {
                $global:LASTEXITCODE = 1
                Write-Error "Account '$Name' has login data in $profileDir. Removing the profile deletes it permanently — re-run with -Force if you are sure."
                return
            }
            Remove-Item -LiteralPath $profileDir -Recurse -Force -Confirm:$false
            Write-Host "Account '$Name' removed ($profileDir deleted)." -ForegroundColor Green
        }

        'use' {
            if (-not $Name) { $global:LASTEXITCODE = 1; Write-Error 'Usage: claude-account use <name>   (use "default" to go back to normal)'; return }
            $externalConfigDir = ($env:CLAUDE_CONFIG_DIR -and -not $env:CLAUDE_ACCOUNT)
            if ($Name -eq 'default') {
                if ($externalConfigDir) {
                    Write-Warning "CLAUDE_CONFIG_DIR=$env:CLAUDE_CONFIG_DIR was set outside this tool — removing it from the session; set it again manually if you need it."
                }
                Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
                Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
                Write-Host "This terminal is back on the 'default' account (~\.claude)." -ForegroundColor Green
                return
            }
            $accounts = Get-ClaudeAccounts
            if (-not $accounts.Contains($Name)) {
                $global:LASTEXITCODE = 1
                Write-Error "Account '$Name' does not exist. Accounts: $($accounts.Keys -join ', ')"
                return
            }
            if ($externalConfigDir) {
                Write-Warning "CLAUDE_CONFIG_DIR=$env:CLAUDE_CONFIG_DIR was set outside this tool and will be overwritten in this session ('claude-account use default' will not restore it)."
            }
            $env:CLAUDE_ACCOUNT    = $Name
            $env:CLAUDE_CONFIG_DIR = $accounts[$Name]
            Write-Host "This terminal now uses account '$Name'. (This session only.)" -ForegroundColor Green
        }

        'current' {
            $account = Resolve-ClaudeAccount
            $dir = $account.Dir
            if (-not $dir) { $dir = Get-ClaudeDefaultDir }
            $email = Get-ClaudeAccountEmail -Dir $dir
            if (-not $email) { $email = '(no login)' }
            [pscustomobject]@{
                Account   = $account.Name
                Login     = $email
                Directory = $dir
                Source    = $account.Source
            }
        }

        'bind' {
            if (-not $Name) { $global:LASTEXITCODE = 1; Write-Error 'Usage: claude-account bind <name>   (creates .claude-account in the current directory)'; return }
            $accounts = Get-ClaudeAccounts
            if (-not $accounts.Contains($Name)) {
                $global:LASTEXITCODE = 1
                Write-Error "Account '$Name' does not exist. Create it first with: claude-account add $Name"
                return
            }
            $file = Join-Path (Get-Location).ProviderPath $script:MarkerFileName
            Set-Content -LiteralPath $file -Value $Name -Encoding Ascii
            Write-Host "Directory bound to account '$Name' ($file)." -ForegroundColor Green
            Write-Host 'Run it at the repository root so it applies to all subdirectories. Commitable, like an .nvmrc.'
        }

        'unbind' {
            $file = Join-Path (Get-Location).ProviderPath $script:MarkerFileName
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                Remove-Item -LiteralPath $file -Confirm:$false
                Write-Host "Binding removed ($file)." -ForegroundColor Green
            } else {
                Write-Host "No $script:MarkerFileName file in this directory."
            }
        }

        'migrate' {
            if (-not $Name) { $global:LASTEXITCODE = 1; Write-Error 'Usage: claude-account migrate <name> [-From <name>]   (copies tools/content into a profile; default source is the default account)'; return }
            $accounts = Get-ClaudeAccounts
            if ($Name -eq 'default') { $global:LASTEXITCODE = 1; Write-Error "Cannot migrate INTO 'default'. Choose a profile as the destination."; return }
            if (-not $accounts.Contains($Name)) {
                $global:LASTEXITCODE = 1
                Write-Error "Account '$Name' does not exist. Create it first with: claude-account add $Name"
                return
            }
            $fromName = 'default'
            if ($From) { $fromName = $From }
            if (-not $accounts.Contains($fromName)) {
                $global:LASTEXITCODE = 1
                Write-Error "Source account '$fromName' does not exist. Accounts: $($accounts.Keys -join ', ')"
                return
            }
            if ($fromName -eq $Name) { $global:LASTEXITCODE = 1; Write-Error "Source and destination are the same ('$Name')."; return }
            $srcDir = Get-ClaudeDefaultDir
            if ($fromName -ne 'default') { $srcDir = $accounts[$fromName] }
            $dstDir = $accounts[$Name]
            Write-Host "Migrating tools and content from '$fromName' into '$Name'..."
            $copied = Copy-ClaudeProfileContent -Source $srcDir -Destination $dstDir
            if ($copied.Count -gt 0) {
                Write-Host "Copied into '$Name': $($copied -join ', ')" -ForegroundColor Green
            } else {
                Write-Host "Nothing to copy — '$Name' already has those items (existing data is never overwritten)." -ForegroundColor Yellow
            }
            Write-Host "Login and caches were not touched; '$Name' keeps its own credentials." -ForegroundColor DarkGray
        }

        'doctor' {
            $caHome   = Get-ClaudeAccountsHome
            $shimDir  = Get-ClaudeShimDir
            $exe      = Get-ClaudeExecutable
            $account  = $null
            try { $account = Resolve-ClaudeAccount } catch {}

            Write-Host ''
            Write-Host "claude-accounts doctor  (v$script:Version)" -ForegroundColor Cyan
            Write-Host ''
            Write-Host 'Paths'
            Write-Host "  Home      : $caHome"
            Write-Host "  Profiles  : $profilesRoot"
            Write-Host "  Shim dir  : $shimDir"
            Write-Host "  Default   : $(Get-ClaudeDefaultDir)"
            Write-Host ''
            Write-Host 'claude binary'
            if ($exe) { Write-Host "  [ok] real claude: $exe" -ForegroundColor Green }
            else { Write-Host '  [!!] claude executable not found on PATH. Install Claude Code.' -ForegroundColor Red }
            Write-Host ''
            Write-Host 'Effective account (this shell, this directory)'
            if ($account) {
                $dir = $account.Dir; if (-not $dir) { $dir = Get-ClaudeDefaultDir }
                Write-Host "  Account   : $($account.Name)"
                Write-Host "  Directory : $dir"
                Write-Host "  Source    : $($account.Source)"
                if ($account.Name -eq 'default') {
                    Write-Host '  [i] You are on the DEFAULT account: skills/agents/plugins/logins created now land in' -ForegroundColor Yellow
                    Write-Host "      $(Get-ClaudeDefaultDir), not in a profile. Use 'claude --account <name>' or 'claude-account bind <name>'." -ForegroundColor Yellow
                }
            } else {
                Write-Host '  [!!] could not resolve the account.' -ForegroundColor Red
            }
            Write-Host ''
            Write-Host 'Shell integrations'
            $psOk = $false
            foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost)) {
                if ($p -and (Test-Path -LiteralPath $p -PathType Leaf) -and
                    (Select-String -LiteralPath $p -Pattern 'claude-accounts' -Quiet -ErrorAction SilentlyContinue)) { $psOk = $true; break }
            }
            if ($psOk) { Write-Host '  [ok] PowerShell profile imports the module' -ForegroundColor Green }
            else { Write-Host '  [!] PowerShell profile has no claude-accounts block (run install.ps1)' -ForegroundColor Yellow }

            $shimPresent = Test-Path -LiteralPath (Join-Path $shimDir 'claude.cmd') -PathType Leaf
            $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
            $inPath = $false
            if ($userPath) {
                foreach ($p in ($userPath -split ';')) {
                    if ($p -and ($p.TrimEnd('\', '/') -ieq $shimDir.TrimEnd('\', '/'))) { $inPath = $true; break }
                }
            }
            if ($shimPresent -and $inPath) { Write-Host '  [ok] cmd shims installed and on PATH' -ForegroundColor Green }
            elseif ($shimPresent) { Write-Host '  [!] cmd shims exist but the shim dir is not on your User PATH (run install.ps1)' -ForegroundColor Yellow }
            else { Write-Host '  [!] cmd shims not installed (run install.ps1) - cmd.exe bypasses the wrapper' -ForegroundColor Yellow }

            $bashrc = Join-Path $env:USERPROFILE '.bashrc'
            if ((Test-Path -LiteralPath $bashrc -PathType Leaf) -and
                (Select-String -LiteralPath $bashrc -Pattern 'claude-accounts' -Quiet -ErrorAction SilentlyContinue)) {
                Write-Host '  [ok] Git Bash ~/.bashrc sources the script' -ForegroundColor Green
            } else {
                Write-Host '  [!] Git Bash ~/.bashrc has no claude-accounts block (run install.ps1)' -ForegroundColor Yellow
            }
            Write-Host ''
        }

        'version' {
            Write-Host "claude-accounts $script:Version (https://github.com/sppeect/claude-accounts)"
        }

        default {
            Write-Host ''
            Write-Host "claude-account — Claude Code account profiles (AWS CLI style) v$script:Version" -ForegroundColor Cyan
            Write-Host ''
            Write-Host '  claude-account list              list accounts and who is logged into each'
            Write-Host '  claude-account add <name>        create an account (inherits tools from default) and log in'
            Write-Host '  claude-account add <name> -Minimal     inherit only settings.json (no skills/agents/content)'
            Write-Host '  claude-account add <name> -NoLogin     create without logging in (login on first run)'
            Write-Host '  claude-account remove <name> [-Force]  delete a profile (-Force when it has login data)'
            Write-Host '  claude-account use <name>        pin the account to this terminal (use default to undo)'
            Write-Host '  claude-account bind <name>       bind the current directory to an account (.claude-account)'
            Write-Host '  claude-account unbind            remove the current directory binding'
            Write-Host '  claude-account current           show the effective account and where it came from'
            Write-Host '  claude-account migrate <name> [-From <name>]  copy tools/content from default (or -From) into a profile'
            Write-Host '  claude-account doctor            check the install across PowerShell, cmd and Git Bash'
            Write-Host ''
            Write-Host '  claude --account <name> [...]    run Claude Code with the chosen account'
            Write-Host ''
            Write-Host 'Priority: --account > use (terminal) > external CLAUDE_CONFIG_DIR > .claude-account (directory) > default'
            Write-Host ''
        }
    }
}

Export-ModuleMember -Function claude, claude-account, Get-ClaudeAccounts, Resolve-ClaudeAccount, Get-ClaudeExecutable, Copy-ClaudeProfileContent

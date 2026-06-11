#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ============================================================================
# Pester 5 suite for claude-accounts (src/ClaudeAccounts.psm1).
#
# The real claude binary is NEVER touched: a mock claude.cmd is placed in a
# directory prepended to PATH. The mock prints
#   MOCK cfg=<CLAUDE_CONFIG_DIR> acct=<CLAUDE_ACCOUNT> args=<argv>
# and exits with %MOCK_EXIT% (default 0). The registry and the default dir
# are isolated in $TestDrive via CLAUDE_ACCOUNTS_HOME and
# CLAUDE_ACCOUNTS_DEFAULT_DIR.
#
# An EMPTY .claude-account marker is planted at the TestDrive root: an empty
# marker stops the upward walk, so bindings in ancestors of the temp dir
# (the developer machine, CI image, ...) can never leak into these tests.
# ============================================================================

Describe 'claude-accounts (PowerShell module)' {

    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\src\ClaudeAccounts.psm1') -Force -DisableNameChecking

        # Renders any mix of strings / ErrorRecord / WarningRecord /
        # InformationRecord as plain text without console line wrapping.
        function AsText { param($Items) (@($Items) | ForEach-Object { "$_" }) -join "`n" }

        # --- snapshot of everything we mutate -------------------------------
        $script:SavedPath      = $env:PATH
        $script:SavedHome      = $env:CLAUDE_ACCOUNTS_HOME
        $script:SavedDefault   = $env:CLAUDE_ACCOUNTS_DEFAULT_DIR
        $script:SavedAccount   = $env:CLAUDE_ACCOUNT
        $script:SavedConfigDir = $env:CLAUDE_CONFIG_DIR
        $script:SavedMockExit  = $env:MOCK_EXIT
        $script:SavedLocation  = (Get-Location).ProviderPath

        # --- isolated registry and default dir ------------------------------
        $env:CLAUDE_ACCOUNTS_HOME        = Join-Path $TestDrive 'accounts-home'
        $env:CLAUDE_ACCOUNTS_DEFAULT_DIR = Join-Path $TestDrive 'default-claude'
        New-Item -ItemType Directory -Path $env:CLAUDE_ACCOUNTS_HOME        -Force | Out-Null
        New-Item -ItemType Directory -Path $env:CLAUDE_ACCOUNTS_DEFAULT_DIR -Force | Out-Null
        Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:MOCK_EXIT         -ErrorAction SilentlyContinue

        $script:DefaultDir   = $env:CLAUDE_ACCOUNTS_DEFAULT_DIR
        $script:ProfilesRoot = Join-Path $env:CLAUDE_ACCOUNTS_HOME 'profiles'

        # --- mock claude.cmd, first on PATH ---------------------------------
        $script:MockBin = Join-Path $TestDrive 'mockbin'
        New-Item -ItemType Directory -Path $script:MockBin -Force | Out-Null
        @(
            '@echo off'
            'echo MOCK cfg=%CLAUDE_CONFIG_DIR% acct=%CLAUDE_ACCOUNT% args=%*'
            'if "%MOCK_EXIT%"=="" exit /b 0'
            'exit /b %MOCK_EXIT%'
        ) | Set-Content -LiteralPath (Join-Path $script:MockBin 'claude.cmd') -Encoding Ascii
        $env:PATH = "$($script:MockBin);$env:PATH"

        # --- fixture accounts (created straight on the filesystem) ----------
        $script:WorkDir     = Join-Path $script:ProfilesRoot 'work'
        $script:PersonalDir = Join-Path $script:ProfilesRoot 'personal'
        New-Item -ItemType Directory -Path $script:WorkDir     -Force | Out-Null
        New-Item -ItemType Directory -Path $script:PersonalDir -Force | Out-Null

        # Guard marker (see header comment).
        Set-Content -LiteralPath (Join-Path $TestDrive '.claude-account') -Value '' -Encoding Ascii

        # Neutral cwd for the tests + a dir used as "external" CLAUDE_CONFIG_DIR.
        $script:WorkArea = Join-Path $TestDrive 'work-area'
        New-Item -ItemType Directory -Path $script:WorkArea -Force | Out-Null
        $script:ExternalDir = Join-Path $TestDrive 'external-cfg'
        New-Item -ItemType Directory -Path $script:ExternalDir -Force | Out-Null
        Set-Location $script:WorkArea
    }

    AfterAll {
        if ($script:SavedLocation) { Set-Location $script:SavedLocation }
        if ($null -ne $script:SavedPath) { $env:PATH = $script:SavedPath }
        foreach ($pair in @(
            @{ Name = 'CLAUDE_ACCOUNTS_HOME';        Value = $script:SavedHome },
            @{ Name = 'CLAUDE_ACCOUNTS_DEFAULT_DIR'; Value = $script:SavedDefault },
            @{ Name = 'CLAUDE_ACCOUNT';              Value = $script:SavedAccount },
            @{ Name = 'CLAUDE_CONFIG_DIR';           Value = $script:SavedConfigDir },
            @{ Name = 'MOCK_EXIT';                   Value = $script:SavedMockExit }
        )) {
            if ($null -ne $pair.Value) { Set-Item -Path "Env:$($pair.Name)" -Value $pair.Value }
            else { Remove-Item -Path "Env:$($pair.Name)" -ErrorAction SilentlyContinue }
        }
        Remove-Module ClaudeAccounts -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Set-Location $script:WorkArea
    }

    AfterEach {
        # Every It must leave the session env clean (required by the contract).
        Remove-Item Env:CLAUDE_ACCOUNT    -ErrorAction SilentlyContinue
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:MOCK_EXIT         -ErrorAction SilentlyContinue
        Set-Location $script:WorkArea
        if (Test-Path -LiteralPath (Join-Path $script:WorkArea '.claude-account')) {
            Remove-Item -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Force
        }
    }

    # ========================================================================
    Context 'claude-account add' {

        It 'creates a profile directory and registers the account' {
            $dir = Join-Path $script:ProfilesRoot 'addtest'
            try {
                $out = AsText (claude-account add addtest -NoLogin 6>&1)
                $out | Should -Match "Account 'addtest' created at"
                $out | Should -Match 'To authenticate later'
                Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
                (Get-ClaudeAccounts)['addtest'] | Should -Be $dir
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'rejects an invalid profile name with exit code 1' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account add 'bad name' 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Invalid name: 'bad name'"
            Test-Path -LiteralPath (Join-Path $script:ProfilesRoot 'bad name') | Should -BeFalse
        }

        It 'rejects a duplicate account name with exit code 1' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account add work 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Account 'work' already exists"
        }

        It "treats 'default' as reserved (it always already exists)" {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account add default 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Account 'default' already exists"
            Test-Path -LiteralPath (Join-Path $script:ProfilesRoot 'default') | Should -BeFalse
        }

        It 'creates a .path redirect with -Path and the wrapper resolves through it' {
            $target   = Join-Path $TestDrive 'custom-target'
            $pathFile = Join-Path $script:ProfilesRoot 'custom.path'
            try {
                $out = AsText (claude-account add custom -Path $target -NoLogin 6>&1)
                $out | Should -Match "Account 'custom' created at"
                Test-Path -LiteralPath $pathFile -PathType Leaf  | Should -BeTrue
                Test-Path -LiteralPath $target -PathType Container | Should -BeTrue
                (Get-Content -LiteralPath $pathFile -TotalCount 1) | Should -Be $target
                (Get-ClaudeAccounts)['custom'] | Should -Be $target
                AsText (claude '--account' 'custom' 'ping' 3>$null) |
                    Should -Be "MOCK cfg=$target acct=custom args=ping"
            } finally {
                Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # ========================================================================
    Context 'claude-account list' {

        It 'lists default plus the registered accounts with their directories' {
            $rows  = claude-account list 3>$null
            $names = @($rows | ForEach-Object Account)
            $names | Should -Contain 'default'
            $names | Should -Contain 'work'
            $names | Should -Contain 'personal'
            ($rows | Where-Object Account -eq 'default').Directory | Should -Be $script:DefaultDir
            ($rows | Where-Object Account -eq 'work').Directory    | Should -Be $script:WorkDir
            ($rows | Where-Object Account -eq 'work').Login        | Should -BeLike '(no login*'
        }

        It 'shows the logged-in email read from .claude.json' {
            $dir = Join-Path $script:ProfilesRoot 'mailacct'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $dir '.claude.json') `
                    -Value '{"oauthAccount":{"emailAddress":"mail@example.com"}}' -Encoding UTF8
                $rows = claude-account list 3>$null
                ($rows | Where-Object Account -eq 'mailacct').Login | Should -Be 'mail@example.com'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }

        It 'shows (logged in) when only .credentials.json exists' {
            $dir = Join-Path $script:ProfilesRoot 'credlist'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            try {
                Set-Content -LiteralPath (Join-Path $dir '.credentials.json') -Value '{}' -Encoding Ascii
                $rows = claude-account list 3>$null
                ($rows | Where-Object Account -eq 'credlist').Login | Should -Be '(logged in)'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force
            }
        }

        It 'flags the active account with *' {
            $env:CLAUDE_ACCOUNT = 'personal'
            $rows = claude-account list 3>$null
            ($rows | Where-Object Account -eq 'personal').Active | Should -Be '*'
            ($rows | Where-Object Account -eq 'default').Active  | Should -Be ''
        }
    }

    # ========================================================================
    Context 'claude-account remove' {

        It 'fails with exit code 1 for a nonexistent account' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account remove ghost 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Account 'ghost' does not exist"
        }

        It "refuses to remove the 'default' account" {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account remove default 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match 'cannot be removed'
        }

        It 'guards profiles with login data unless -Force is given' {
            $dir = Join-Path $script:ProfilesRoot 'credacct'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir '.credentials.json') -Value '{}' -Encoding Ascii
            try {
                $global:LASTEXITCODE = 0
                $err = AsText (claude-account remove credacct 2>&1)
                $LASTEXITCODE | Should -Be 1
                $err | Should -Match 'has login data'
                Test-Path -LiteralPath $dir | Should -BeTrue

                $out = AsText (claude-account remove credacct -Force 6>&1)
                $out | Should -Match "Account 'credacct' removed"
                Test-Path -LiteralPath $dir | Should -BeFalse
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'removes a profile without -Force when it has no login data' {
            $dir = Join-Path $script:ProfilesRoot 'plain'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $out = AsText (claude-account remove plain 6>&1)
            $out | Should -Match "Account 'plain' removed"
            Test-Path -LiteralPath $dir | Should -BeFalse
        }

        It 'removes only the redirect file for .path accounts (target untouched)' {
            $target   = Join-Path $TestDrive 'redir-target'
            $pathFile = Join-Path $script:ProfilesRoot 'redir.path'
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            Set-Content -LiteralPath $pathFile -Value $target -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $target '.credentials.json') -Value '{}' -Encoding Ascii
            try {
                $out = AsText (claude-account remove redir 6>&1)
                $out | Should -Match 'redirect file deleted'
                $out | Should -Match 'NOT touched'
                Test-Path -LiteralPath $pathFile | Should -BeFalse
                Test-Path -LiteralPath (Join-Path $target '.credentials.json') | Should -BeTrue
            } finally {
                Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'switches the terminal back to default when removing the active account' {
            $dir = Join-Path $script:ProfilesRoot 'active'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $env:CLAUDE_ACCOUNT    = 'active'
            $env:CLAUDE_CONFIG_DIR = $dir
            $out = AsText (claude-account remove active 6>&1)
            $out | Should -Match "This terminal was using 'active'"
            $env:CLAUDE_ACCOUNT    | Should -BeNullOrEmpty
            $env:CLAUDE_CONFIG_DIR | Should -BeNullOrEmpty
            Test-Path -LiteralPath $dir | Should -BeFalse
        }
    }

    # ========================================================================
    Context 'registry (Get-ClaudeAccounts)' {

        It 'lets a .path file win over a directory of the same name' {
            $dupDir   = Join-Path $script:ProfilesRoot 'dup'
            $dupPath  = Join-Path $script:ProfilesRoot 'dup.path'
            $target   = Join-Path $TestDrive 'dup-target'
            New-Item -ItemType Directory -Path $dupDir -Force | Out-Null
            Set-Content -LiteralPath $dupPath -Value $target -Encoding UTF8
            try {
                $mix  = Get-ClaudeAccounts 3>&1
                $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $map  = $mix | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }
                $warn | Should -Match '\.path file wins'
                $map['dup'] | Should -Be $target
            } finally {
                Remove-Item -LiteralPath $dupDir -Recurse -Force
                Remove-Item -LiteralPath $dupPath -Force
            }
        }

        It "ignores a profiles\default directory with a warning ('default' is reserved)" {
            $resDir = Join-Path $script:ProfilesRoot 'default'
            New-Item -ItemType Directory -Path $resDir -Force | Out-Null
            try {
                $mix  = Get-ClaudeAccounts 3>&1
                $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $map  = $mix | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }
                $warn | Should -Match 'reserved'
                $map['default'] | Should -Be $script:DefaultDir
            } finally {
                Remove-Item -LiteralPath $resDir -Recurse -Force
            }
        }

        It 'expands a leading ~ in .path targets' {
            $f = Join-Path $script:ProfilesRoot 'til.path'
            Set-Content -LiteralPath $f -Value '~\tilde-target' -Encoding UTF8
            try {
                (Get-ClaudeAccounts)['til'] | Should -Be (Join-Path $env:USERPROFILE 'tilde-target')
            } finally {
                Remove-Item -LiteralPath $f -Force
            }
        }

        It 'ignores an empty .path redirect with a warning' {
            $f = Join-Path $script:ProfilesRoot 'empty.path'
            Set-Content -LiteralPath $f -Value '' -Encoding UTF8
            try {
                $mix  = Get-ClaudeAccounts 3>&1
                $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
                $map  = $mix | Where-Object { $_ -is [System.Collections.Specialized.OrderedDictionary] }
                $warn | Should -Match "profile 'empty' ignored"
                $map.Contains('empty') | Should -BeFalse
            } finally {
                Remove-Item -LiteralPath $f -Force
            }
        }
    }

    # ========================================================================
    Context 'account resolution (5 priorities)' {

        It '1) the --account flag beats use, external dir and marker' {
            Set-Content -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Value 'personal' -Encoding Ascii
            $env:CLAUDE_ACCOUNT    = 'personal'
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            $res = Resolve-ClaudeAccount -Explicit 'work' 3>$null
            $res.Name   | Should -Be 'work'
            $res.Dir    | Should -Be $script:WorkDir
            $res.Source | Should -Be '--account flag'
        }

        It '2) CLAUDE_ACCOUNT (use) beats external CLAUDE_CONFIG_DIR and marker' {
            Set-Content -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Value 'personal' -Encoding Ascii
            $env:CLAUDE_ACCOUNT    = 'work'
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            $res = Resolve-ClaudeAccount 3>$null
            $res.Name   | Should -Be 'work'
            $res.Dir    | Should -Be $script:WorkDir
            $res.Source | Should -Be 'claude-account use (this terminal)'
        }

        It '3) an external CLAUDE_CONFIG_DIR beats the marker and reports (external)' {
            Set-Content -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Value 'personal' -Encoding Ascii
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            $mix  = Resolve-ClaudeAccount 3>&1
            $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $res  = $mix | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $res.Name   | Should -Be '(external)'
            $res.Dir    | Should -Be $script:ExternalDir
            $res.Source | Should -Be 'pre-existing CLAUDE_CONFIG_DIR in the environment'
            $warn | Should -Match 'takes priority'
        }

        It '4) the .claude-account marker is used when no env var is set' {
            Set-Content -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Value 'personal' -Encoding Ascii
            $res = Resolve-ClaudeAccount
            $res.Name   | Should -Be 'personal'
            $res.Dir    | Should -Be $script:PersonalDir
            $res.Source | Should -BeLike 'file *work-area\.claude-account'
        }

        It '5) falls back to default when nothing is configured' {
            $res = Resolve-ClaudeAccount 3>$null
            $res.Name   | Should -Be 'default'
            $res.Dir    | Should -BeNullOrEmpty
            $res.Source | Should -Be 'default (~\.claude)'
        }

        It 'throws for an unknown explicit account' {
            { Resolve-ClaudeAccount -Explicit 'ghost' } | Should -Throw "*Account 'ghost' does not exist*"
        }

        It 'warns when the flag overrides a directory binding' {
            Set-Content -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Value 'personal' -Encoding Ascii
            $mix  = Resolve-ClaudeAccount -Explicit 'work' 3>&1
            $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $res  = $mix | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $res.Name | Should -Be 'work'
            $warn | Should -Match "bound to account 'personal'"
            $warn | Should -Match "Proceeding with 'work'"
        }

        It 'warns and falls back to default when the marker names an unknown account' {
            Set-Content -LiteralPath (Join-Path $script:WorkArea '.claude-account') -Value 'ghostacct' -Encoding Ascii
            $mix  = Resolve-ClaudeAccount 3>&1
            $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $res  = $mix | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $res.Name | Should -Be 'default'
            $warn | Should -Match "unknown account 'ghostacct'"
        }

        It 'residual pair: invalid CLAUDE_ACCOUNT plus CLAUDE_CONFIG_DIR resolves to default' {
            $env:CLAUDE_ACCOUNT    = 'ghost'
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            $mix  = Resolve-ClaudeAccount 3>&1
            $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $res  = $mix | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $res.Name | Should -Be 'default'
            $warn | Should -Match "CLAUDE_ACCOUNT='ghost' does not match"
            $warn | Should -Match 'residual CLAUDE_CONFIG_DIR'
        }
    }

    # ========================================================================
    Context 'marker walking (.claude-account)' {

        It 'finds a marker in a parent directory from a subdirectory' {
            $proj = Join-Path $TestDrive 'proj'
            $sub  = Join-Path $proj 'a\b'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $proj '.claude-account') -Value 'work' -Encoding Ascii
            Set-Location $sub
            $res = Resolve-ClaudeAccount
            $res.Name   | Should -Be 'work'
            $res.Dir    | Should -Be $script:WorkDir
            $res.Source | Should -BeLike 'file *proj\.claude-account'
        }

        It 'an empty marker stops the walk before a parent binding' {
            $stop = Join-Path $TestDrive 'stop'
            $sub  = Join-Path $stop 'sub'
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $stop '.claude-account') -Value 'work' -Encoding Ascii
            Set-Content -LiteralPath (Join-Path $sub '.claude-account')  -Value ''     -Encoding Ascii
            Set-Location $sub
            $mix  = Resolve-ClaudeAccount 3>&1
            $warn = AsText ($mix | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
            $res  = $mix | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
            $res.Name | Should -Be 'default'
            $warn | Should -Match 'account binding ignored'
        }

        It 'tolerates CRLF and surrounding whitespace in the marker' {
            $crlf = Join-Path $TestDrive 'crlf'
            New-Item -ItemType Directory -Path $crlf -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $crlf '.claude-account'), "  work  `r`n")
            Set-Location $crlf
            $res = Resolve-ClaudeAccount
            $res.Name | Should -Be 'work'
            $res.Dir  | Should -Be $script:WorkDir
        }
    }

    # ========================================================================
    Context 'claude wrapper: prefix parsing and invocation' {

        It 'runs the child with CLAUDE_CONFIG_DIR and CLAUDE_ACCOUNT set together for --account' {
            $out = AsText (claude '--account' 'work' 'run' 'now' 3>$null)
            $out | Should -Be "MOCK cfg=$($script:WorkDir) acct=work args=run now"
            $LASTEXITCODE | Should -Be 0
        }

        It 'accepts -a as an alias for --account' {
            AsText (claude '-a' 'personal' 'x' 3>$null) |
                Should -Be "MOCK cfg=$($script:PersonalDir) acct=personal args=x"
        }

        It 'accepts the --account=<name> form' {
            AsText (claude '--account=work' 'y' 3>$null) |
                Should -Be "MOCK cfg=$($script:WorkDir) acct=work args=y"
        }

        It 'fails with exit code 1 when --account= has an empty value' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude '--account=' 2>&1 3>$null)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match 'the value is empty'
            $err | Should -Not -Match 'MOCK'
        }

        It 'fails with exit code 1 when --account has no value' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude '--account' 2>&1 3>$null)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match 'Usage: claude --account <name>'
            $err | Should -Not -Match 'MOCK'
        }

        It 'passes -a through untouched after the first positional argument' {
            $mix = claude 'foo' '-a' 'work' 3>&1
            $txt = AsText $mix
            $txt | Should -Match 'MOCK cfg= acct= args=foo -a work'
            $txt | Should -Not -Match 'after the first positional'
        }

        It 'warns about --account after a positional argument and passes it through' {
            $mix = claude 'foo' '--account' 'work' 3>&1
            $txt = AsText $mix
            $txt | Should -Match 'after the first positional argument'
            $txt | Should -Match 'MOCK cfg= acct= args=foo --account work'
        }

        It 'lets the last prefix flag win when repeated' {
            AsText (claude '-a' 'work' '--account' 'personal' 'z' 3>$null) |
                Should -Be "MOCK cfg=$($script:PersonalDir) acct=personal args=z"
        }

        It 'clears both variables in the child for the default account' {
            AsText (claude 'hi' 3>$null) | Should -Be 'MOCK cfg= acct= args=hi'
        }

        It 'keeps CLAUDE_CONFIG_DIR and clears CLAUDE_ACCOUNT for (external)' {
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            AsText (claude 'x' 3>$null) |
                Should -Be "MOCK cfg=$($script:ExternalDir) acct= args=x"
        }

        It 'runs default with both variables cleared for the residual pair' {
            $env:CLAUDE_ACCOUNT    = 'ghost'
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            AsText (claude 'z' 3>$null) | Should -Be 'MOCK cfg= acct= args=z'
        }

        It 'restores the environment after the invocation (previously unset)' {
            claude '--account' 'work' 3>$null | Out-Null
            $env:CLAUDE_CONFIG_DIR | Should -BeNullOrEmpty
            $env:CLAUDE_ACCOUNT    | Should -BeNullOrEmpty
        }

        It 'restores the environment after the invocation (previously set by use)' {
            $env:CLAUDE_ACCOUNT    = 'work'
            $env:CLAUDE_CONFIG_DIR = $script:WorkDir
            AsText (claude 'q' 3>$null) |
                Should -Be "MOCK cfg=$($script:WorkDir) acct=work args=q"
            $env:CLAUDE_ACCOUNT    | Should -Be 'work'
            $env:CLAUDE_CONFIG_DIR | Should -Be $script:WorkDir
        }
    }

    # ========================================================================
    Context 'exit codes' {

        It 'sets exit code 1 for a nonexistent account and never calls the child' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude '--account' 'ghost' 2>&1 3>$null)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Account 'ghost' does not exist"
            $err | Should -Not -Match 'MOCK'
        }

        It 'propagates the child exit code (MOCK_EXIT=7)' {
            $env:MOCK_EXIT = '7'
            $out = AsText (claude '--account' 'work' 3>$null)
            $LASTEXITCODE | Should -Be 7
            $out | Should -Match 'MOCK'
        }

        It 'reports exit code 0 on success' {
            $global:LASTEXITCODE = 99
            claude '--account' 'work' 3>$null | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }

    # ========================================================================
    Context 'bind / unbind / current / use' {

        It 'bind writes the marker and current reports the file source' {
            $bindDir = Join-Path $TestDrive 'bindtest'
            New-Item -ItemType Directory -Path $bindDir -Force | Out-Null
            Set-Location $bindDir
            $out = AsText (claude-account bind work 6>&1)
            $out | Should -Match "Directory bound to account 'work'"
            $marker = Join-Path $bindDir '.claude-account'
            Test-Path -LiteralPath $marker -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $marker -TotalCount 1) | Should -Be 'work'

            $cur = claude-account current
            $cur.Account   | Should -Be 'work'
            $cur.Directory | Should -Be $script:WorkDir
            $cur.Login     | Should -Be '(no login)'
            $cur.Source    | Should -BeLike 'file *bindtest\.claude-account'

            AsText (claude 'go') | Should -Be "MOCK cfg=$($script:WorkDir) acct=work args=go"
        }

        It 'bind fails with exit code 1 for an unknown account' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account bind ghost 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Account 'ghost' does not exist"
            Test-Path -LiteralPath (Join-Path $script:WorkArea '.claude-account') | Should -BeFalse
        }

        It 'unbind removes the marker and reports when none exists' {
            $dir = Join-Path $TestDrive 'unbindtest'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Location $dir
            claude-account bind personal 6>$null
            Test-Path -LiteralPath (Join-Path $dir '.claude-account') | Should -BeTrue

            $out = AsText (claude-account unbind 6>&1)
            $out | Should -Match 'Binding removed'
            Test-Path -LiteralPath (Join-Path $dir '.claude-account') | Should -BeFalse

            AsText (claude-account unbind 6>&1) | Should -Match 'No \.claude-account file'
        }

        It 'use pins the account to the terminal (env pair set together)' {
            $out = AsText (claude-account use work 6>&1)
            $out | Should -Match "now uses account 'work'"
            $env:CLAUDE_ACCOUNT    | Should -Be 'work'
            $env:CLAUDE_CONFIG_DIR | Should -Be $script:WorkDir

            $cur = claude-account current
            $cur.Account | Should -Be 'work'
            $cur.Source  | Should -Be 'claude-account use (this terminal)'

            AsText (claude 'p') | Should -Be "MOCK cfg=$($script:WorkDir) acct=work args=p"
        }

        It 'use default clears both variables' {
            claude-account use personal 6>$null
            $out = AsText (claude-account use default 6>&1)
            $out | Should -Match "back on the 'default' account"
            $env:CLAUDE_ACCOUNT    | Should -BeNullOrEmpty
            $env:CLAUDE_CONFIG_DIR | Should -BeNullOrEmpty
        }

        It 'use fails with exit code 1 for an unknown account' {
            $global:LASTEXITCODE = 0
            $err = AsText (claude-account use ghost 2>&1)
            $LASTEXITCODE | Should -Be 1
            $err | Should -Match "Account 'ghost' does not exist"
            $env:CLAUDE_ACCOUNT | Should -BeNullOrEmpty
        }

        It 'use default warns when an external CLAUDE_CONFIG_DIR is dropped' {
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            $warn = AsText (claude-account use default 3>&1 6>$null)
            $warn | Should -Match 'set outside this tool'
            $env:CLAUDE_CONFIG_DIR | Should -BeNullOrEmpty
            $env:CLAUDE_ACCOUNT    | Should -BeNullOrEmpty
        }

        It 'use warns before overwriting an external CLAUDE_CONFIG_DIR' {
            $env:CLAUDE_CONFIG_DIR = $script:ExternalDir
            $warn = AsText (claude-account use work 3>&1 6>$null)
            $warn | Should -Match 'will be overwritten'
            $env:CLAUDE_ACCOUNT    | Should -Be 'work'
            $env:CLAUDE_CONFIG_DIR | Should -Be $script:WorkDir
        }

        It 'current reports default when nothing is configured' {
            $cur = claude-account current 3>$null
            $cur.Account   | Should -Be 'default'
            $cur.Login     | Should -Be '(no login)'
            $cur.Directory | Should -Be $script:DefaultDir
            $cur.Source    | Should -Be 'default (~\.claude)'
        }

        It 'prints the version' {
            AsText (claude-account version 6>&1) | Should -Match 'claude-accounts 1\.0\.0'
        }
    }
}

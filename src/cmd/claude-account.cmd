@echo off
REM ===========================================================================
REM claude-accounts management wrapper for cmd.exe.
REM Most subcommands delegate to the PowerShell module. 'use' is special-cased:
REM it must change THIS cmd session's environment, which a child PowerShell
REM cannot do, so the variables are set in the current shell directly.
REM Installed into %USERPROFILE%\.claude-accounts\bin\ (first on PATH).
REM ===========================================================================
if /I "%~1"=="use" goto use
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-account.shim.ps1" %*
exit /b %ERRORLEVEL%

:use
if "%~2"=="" (
    >&2 echo claude-accounts: usage: claude-account use ^<name^>   ^(use "default" to go back to normal^)
    exit /b 1
)
if /I "%~2"=="default" (
    set "CLAUDE_CONFIG_DIR="
    set "CLAUDE_ACCOUNT="
    echo This terminal is back on the 'default' account.
    exit /b 0
)
set "_CA_DIR="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-account-usedir.ps1" "%~2"`) do set "_CA_DIR=%%i"
if not defined _CA_DIR (
    >&2 echo claude-accounts: account '%~2' does not exist. Run: claude-account list
    exit /b 1
)
set "CLAUDE_CONFIG_DIR=%_CA_DIR%"
set "CLAUDE_ACCOUNT=%~2"
set "_CA_DIR="
echo This terminal now uses account '%~2'. (This session only.)
exit /b 0

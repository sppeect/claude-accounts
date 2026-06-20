@echo off
REM ===========================================================================
REM claude-accounts wrapper for cmd.exe.
REM Gives Command Prompt users the same `claude --account <name>` resolution as
REM PowerShell by delegating to the module. Argv is forwarded verbatim
REM (powershell -File preserves quoting, including -- and quoted args) and the
REM child's exit code is propagated. The environment is set inside the child
REM PowerShell only, so nothing leaks into this cmd session.
REM This file is installed into %USERPROFILE%\.claude-accounts\bin\ (first on
REM PATH); the helper script lives next to it.
REM ===========================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude.shim.ps1" %*
exit /b %ERRORLEVEL%

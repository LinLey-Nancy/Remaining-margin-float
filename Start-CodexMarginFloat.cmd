@echo off
setlocal

set "CODEX_MARGIN_FLOAT_SCRIPT=%~dp0src\CodexMarginFloat.ps1"

if not exist "%CODEX_MARGIN_FLOAT_SCRIPT%" (
    echo [Codex Margin Float] Cannot find:
    echo %CODEX_MARGIN_FLOAT_SCRIPT%
    pause
    exit /b 1
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
    "$scriptPath = $env:CODEX_MARGIN_FLOAT_SCRIPT; $quotedPath = [char]34 + $scriptPath + [char]34; Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', $quotedPath) -WindowStyle Hidden"
if errorlevel 1 (
    echo [Codex Margin Float] Failed to start PowerShell.
    pause
    exit /b 1
)

endlocal
exit /b 0

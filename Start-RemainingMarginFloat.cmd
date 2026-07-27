@echo off
setlocal

set "REMAINING_MARGIN_FLOAT_SCRIPT=%~dp0src\RemainingMarginFloat.ps1"

if not exist "%REMAINING_MARGIN_FLOAT_SCRIPT%" (
    echo [Remaining Margin Float] Cannot find:
    echo %REMAINING_MARGIN_FLOAT_SCRIPT%
    pause
    exit /b 1
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
    "$scriptPath = $env:REMAINING_MARGIN_FLOAT_SCRIPT; $quotedPath = [char]34 + $scriptPath + [char]34; Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', $quotedPath) -WindowStyle Hidden"
if errorlevel 1 (
    echo [Remaining Margin Float] Failed to start PowerShell.
    pause
    exit /b 1
)

endlocal
exit /b 0

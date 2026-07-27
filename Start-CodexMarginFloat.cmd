@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0src\CodexMarginFloat.ps1"
endlocal

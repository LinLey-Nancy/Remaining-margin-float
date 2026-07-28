@echo off
setlocal

set "REMAINING_MARGIN_FLOAT_SCRIPT=%~dp0src\RemainingMarginFloat.ps1"
set /p "REMAINING_MARGIN_FLOAT_VERSION="<"%~dp0VERSION"
set "REMAINING_MARGIN_FLOAT_PACKAGE=%~dp0dist\Remaining-Margin-Float-v%REMAINING_MARGIN_FLOAT_VERSION%"
set "REMAINING_MARGIN_FLOAT_EXE=%REMAINING_MARGIN_FLOAT_PACKAGE%\RemainingMarginFloat.exe"
set "REMAINING_MARGIN_FLOAT_PACKAGED_SCRIPT=%REMAINING_MARGIN_FLOAT_PACKAGE%\RemainingMarginFloat.ps1"

if exist "%REMAINING_MARGIN_FLOAT_EXE%" if exist "%REMAINING_MARGIN_FLOAT_PACKAGED_SCRIPT%" (
    if defined REMAINING_MARGIN_FLOAT_START_CHECK (
        echo Mode=PackagedExe
        echo Path=%REMAINING_MARGIN_FLOAT_EXE%
        exit /b 0
    )
    echo [Remaining Margin Float] Starting packaged launcher...
    powershell.exe -NoProfile -NonInteractive -Command ^
        "Start-Process -FilePath $env:REMAINING_MARGIN_FLOAT_EXE -WorkingDirectory $env:REMAINING_MARGIN_FLOAT_PACKAGE"
    if errorlevel 1 (
        echo [Remaining Margin Float] Packaged launcher could not be started.
        pause
        exit /b 1
    )
    exit /b 0
)

if not exist "%REMAINING_MARGIN_FLOAT_SCRIPT%" (
    echo [Remaining Margin Float] Cannot find:
    echo %REMAINING_MARGIN_FLOAT_SCRIPT%
    pause
    exit /b 1
)

if defined REMAINING_MARGIN_FLOAT_START_CHECK (
    echo Mode=PowerShell
    echo Path=%REMAINING_MARGIN_FLOAT_SCRIPT%
    exit /b 0
)

echo [Remaining Margin Float] Packaged launcher not found; starting source mode.
echo [Remaining Margin Float] Keep this window open while the widget is running.
powershell.exe -NoProfile -STA -File "%REMAINING_MARGIN_FLOAT_SCRIPT%"
if errorlevel 1 (
    echo [Remaining Margin Float] PowerShell could not run the application script.
    echo If your organization blocks local scripts, use the packaged launcher instead.
    pause
    exit /b 1
)

endlocal
exit /b 0

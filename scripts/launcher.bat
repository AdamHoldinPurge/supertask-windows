@echo off
REM SuperTask(TM) Windows Launcher — Entry Point v1.10
REM Double-click this file to start SuperTask on Windows.
REM 3-stage boot: updater.ps1 → launcher_win.ps1 → monitor

cd /d "%~dp0"

REM Stage 1: Check for updates (non-blocking, failure-safe)
powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -File "%~dp0updater.ps1"

REM Stage 2: Main application
powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -File "%~dp0launcher_win.ps1"

if errorlevel 1 (
    echo.
    echo [SuperTask] Launch failed with exit code %ERRORLEVEL%.
    echo Generating diagnostic report...
    powershell.exe -STA -ExecutionPolicy Bypass -NoProfile -File "%~dp0debug_report.ps1"
    echo.
    echo Report saved to: %TEMP%\supertask-diagnostic-report.txt
    echo Debug log at: %TEMP%\supertask-debug.log
    echo.
    pause
)

@echo off
rem FFXI Addon Suite installer. Double-click this file. It runs Install-FFXI-Addon-Suite.ps1 next to it.
cd /d "%~dp0"
if not exist "%~dp0Install-FFXI-Addon-Suite.ps1" (
  echo I cannot find Install-FFXI-Addon-Suite.ps1 next to this file.
  echo Unzip the whole download first ^(right-click the ZIP, Extract All^), then run this again.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-FFXI-Addon-Suite.ps1"
if errorlevel 1 (
  echo.
  echo The installer stopped. Read the message above.
  pause
)

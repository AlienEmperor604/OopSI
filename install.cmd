@echo off
rem Installs oopSI - AI Cache Cleaner for the current user (no admin rights needed), then opens it.
rem Full path on purpose: a bare "powershell" is looked up in this folder first, which would let a planted file run.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai-cache-cleaner.ps1" -Install
if errorlevel 1 (
  echo Install failed - see the message above.
  pause
  exit /b 1
)
start "" "%USERPROFILE%\.ai-cache-cleaner\oopSI - AI Cache Cleaner.exe"

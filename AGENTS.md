# Installing AI Cache Cleaner (instructions for AI agents)

The user wants this tool installed on their Windows machine. Everything needed is in this folder:
- `ai-cache-cleaner.ps1` is the whole tool (CLI, app, install, self-test).
- `install.cmd` is the double-click installer for people.
- `logo.png`, `app.ico` and `fonts/` are the app's icon and bundled font.

Nothing is downloaded and no admin rights are needed.

Run every command with **Windows PowerShell 5.1** by its full path, not `pwsh` and not a bare `powershell` (a bare name is looked up in the current folder first). The installer compiles the launcher with the .NET Framework C# compiler, which only Windows PowerShell 5.1 can reach.

```powershell
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
```

## Steps

1. **Unblock** the files in case they came from a downloaded zip:
   ```powershell
   Get-ChildItem -LiteralPath . -Recurse | Unblock-File
   ```
2. **Self-test.** The test only touches a throwaway folder in `%TEMP%`. Expect the output `self-test passed`. If you get anything else, stop and show the user the error.
   ```powershell
   & $ps -NoProfile -ExecutionPolicy Bypass -File .\ai-cache-cleaner.ps1 -Test
   ```
3. **Install.** This copies the tool to `%USERPROFILE%\.ai-cache-cleaner`, builds `oopSI - AI Cache Cleaner.exe` there and creates the desktop shortcut `oopSI - AI Cache Cleaner`. It does **not** schedule anything.
   ```powershell
   & $ps -NoProfile -ExecutionPolicy Bypass -File .\ai-cache-cleaner.ps1 -Install
   ```
4. **Verify** both. Each must print `True`:
   ```powershell
   Test-Path "$env:USERPROFILE\.ai-cache-cleaner\oopSI - AI Cache Cleaner.exe"
   Test-Path ([IO.Path]::Combine([Environment]::GetFolderPath('Desktop'), 'oopSI - AI Cache Cleaner.lnk'))
   ```
5. **Dry run.** This deletes nothing. Summarize the table for the user: how many GB can be freed per cache, plus the "review by hand" list of models and environments.
   ```powershell
   & $ps -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.ai-cache-cleaner\ai-cache-cleaner.ps1"
   ```
6. **Ask about weekly auto-clean.** It's optional and off by default. Ask the user whether they want it and on which day and hour. Only if they say yes:
   ```powershell
   & $ps -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.ai-cache-cleaner\ai-cache-cleaner.ps1" -Schedule -Day Sunday -Hour 13
   ```
7. **Tell the user** how to use it: open **oopSI - AI Cache Cleaner** from the desktop, review the scan, untick anything they want kept, and click **Clean now**. Weekly auto-clean can be switched on or off any time in the app's Settings.

## Rules

- Only run `-Clean` if the user explicitly asks you to clean now. Otherwise leave cleaning to the app's **Clean now** button.
- Never run `-Schedule` without the user's yes, and use the day and hour they chose.
- Never delete anything from the "review by hand" list (models, venvs, conda envs, Python installs) yourself. Report those items and let the user decide.
- Don't change the install location. It's deliberately outside `%LOCALAPPDATA%` and `%APPDATA%`: agents running inside packaged (MSIX) desktop apps get their AppData writes silently redirected into a private copy, so a file written there looks installed to the agent but is missing for the user and for Task Scheduler.
  - If you run inside such an app, ask the user to confirm the exe exists from their own terminal.
- Don't edit the script to "fix" a failing self-test. Report the failure.

## Uninstall

```powershell
& $ps -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.ai-cache-cleaner\ai-cache-cleaner.ps1" -Uninstall
```

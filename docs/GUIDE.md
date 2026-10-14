# How-to guide: AI Cache Cleaner

A step-by-step walkthrough: installing, reading the scan, cleaning, scheduling, the command line, and fixing common problems.

- [1. Install](#1-install)
- [2. The first scan](#2-the-first-scan)
- [3. Choose what to clean](#3-choose-what-to-clean)
- [4. Clean](#4-clean)
- [5. Scan history](#5-scan-history)
- [6. Settings: weekly auto-clean and Temp age](#6-settings-weekly-auto-clean-and-temp-age)
- [7. Command line](#7-command-line)
- [8. Where things live](#8-where-things-live)
- [9. Troubleshooting](#9-troubleshooting)
- [10. Uninstall](#10-uninstall)

## 1. Install

You need Windows 10 or 11. Windows PowerShell 5.1 and .NET Framework 4.x are already part of Windows. You don't need admin rights or an internet connection.

**From the release zip**
1. Download `ai-cache-cleaner-v2.0.3.zip` from the [Releases page](https://github.com/AlienEmperor604/OopSI/releases/latest).
2. Right-click the zip, choose **Extract All**, and open the extracted `ai-cache-cleaner` folder.
3. Double-click **install.cmd**.

**From git**
```powershell
git clone https://github.com/AlienEmperor604/OopSI.git
cd OopSI
.\install.cmd
```

The installer:
- copies the tool to `%USERPROFILE%\.ai-cache-cleaner`
- compiles a small launcher, `oopSI - AI Cache Cleaner.exe`, from source inside the script, using the C# compiler built into Windows
- puts an **oopSI - AI Cache Cleaner** shortcut on your desktop
- does **not** schedule anything; weekly auto-clean stays off until you turn it on

When it finishes, the app opens.

> The install folder is deliberately outside `AppData`. Some packaged (Microsoft Store style) apps silently redirect AppData writes into a private copy, so a tool installed from inside them would look installed but be missing for you and for Task Scheduler.

## 2. The first scan

<img src="screenshots/home.png" alt="Home screen after a scan" width="820">

Opening the app starts a scan straight away. A scan only measures; it never deletes. At the top you'll see:

- **Disk**: free space on your system drive and how full it is
- **Freed this run**: space freed by the last Clean now (0 until you clean)
- **Can be freed**: the total of the ticked caches
- **Items cleared**: how many items the last clean removed
- **Freed all-time**: everything freed since you installed, read from the log

The banner shows progress while scanning ("Measuring caches. Nothing is deleted.") and the result when it's done.

## 3. Choose what to clean

<img src="screenshots/detected-caches.png" alt="Detected caches table" width="820">

The **Detected Cache & Temporary Files** table has one row per cache:

| Column | Meaning |
|---|---|
| Tick box | Ticked caches get cleaned. Untick one to leave it alone; the app remembers your choice, and so does the weekly auto-clean. The box in the header ticks or unticks all of them. |
| Badge and name | Which tool the cache belongs to. |
| Status | Waiting, Scanning, Found, Nothing found, Cleaning, Cleaned, Skipped (unticked or tool not installed) or In use. |
| Items | How many folders or files will be removed. A dash means the tool's own clean command does the work (npm, pnpm, pip, conda). |
| Size / Freed | How big it is now, and how much the last clean freed. |
| Chevron | Expands the row to list the items behind it (up to 100, largest first) or the command that cleans it. |

**Total reclaimable** adds up the ticked rows.

## 4. Clean

Click **Clean now** (top right, or in the banner) and confirm. For each ticked cache the app:

1. scans again, so it acts on the current state
2. skips the cache if its tool is installing something right now
3. for folders it deletes itself (uv, Temp, Playwright): checks that no program runs from the folder and no file inside is open, renames it to `<name>.aicc-del`, then deletes it. Anything still left is retried on the next run.
4. for npm, pnpm, pip and conda: runs the tool's own clean command

The row turns green when it's cleaned, and the **Cleared Items / Activity** card shows the latest item. Anything in use is skipped, not forced.

Only one cleanup runs at a time. If the weekly auto-clean starts while another clean is running, it skips that week.

## 5. Scan history

<img src="screenshots/scan-history.png" alt="Scan history page" width="820">

- **This session** lists every item cleared (or skipped as in use) since the app opened.
- **Past runs** lists every cleanup from `clean.log`: when, manual or auto, space freed and item count.

**Open log** on the Home page opens `clean.log` in Notepad.

## 6. Settings: weekly auto-clean and Temp age

<img src="screenshots/settings.png" alt="Settings page" width="820">

**Weekly auto-clean** is off by default. Flip the switch to turn it on, then pick a day and time. It applies immediately:
- it creates a Windows scheduled task named **AI Cache Cleaner** that runs `oopSI - AI Cache Cleaner.exe -AutoClean`
- the task runs as you, with limited rights, only while you're logged on; if the PC was off at that time it runs at the next chance
- it cleans the same caches you ticked on Home
- **Last auto-clean** shows the result of the most recent run

Turning the switch off deletes the task. The sidebar card shows the current state (for example "Weekly, Sun 13:00") and opens Settings when clicked.

**Temp files older than** sets how old a Temp item must be before it's cleaned (default 7 days, like Windows Disk Cleanup).

## 7. Command line

Use the full path to Windows PowerShell so a file planted in the current folder can't run instead:

```powershell
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$t  = "$env:USERPROFILE\.ai-cache-cleaner\ai-cache-cleaner.ps1"

& $ps -NoProfile -ExecutionPolicy Bypass -File $t              # dry run: table of what can be freed + models to review
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -TempDays 3  # dry run with a different Temp age
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -Clean       # clean now, printing each removed item
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -Gui         # open the app
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -Schedule -Day Saturday -Hour 9   # weekly auto-clean on
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -Unschedule  # weekly auto-clean off
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -Test        # self-test in a throwaway folder
& $ps -NoProfile -ExecutionPolicy Bypass -File $t -Uninstall   # remove everything
```

The dry run ends with a **review by hand** list: the biggest models (Hugging Face, LM Studio, Ollama, ComfyUI, torch) and environments on your machine. The tool never deletes those; the list is there so you can decide.

## 8. Where things live

| Path | What |
|---|---|
| `%USERPROFILE%\.ai-cache-cleaner\ai-cache-cleaner.ps1` | the tool |
| `%USERPROFILE%\.ai-cache-cleaner\oopSI - AI Cache Cleaner.exe` | launcher compiled at install |
| `%USERPROFILE%\.ai-cache-cleaner\settings.json` | your ticks and Temp age: `{ "skip": [...], "tempDays": 7 }` |
| `%USERPROFILE%\.ai-cache-cleaner\clean.log` | one line per cleanup |
| Desktop `oopSI - AI Cache Cleaner.lnk` | shortcut |
| Task Scheduler `AI Cache Cleaner` | only if you turned on weekly auto-clean |

## 9. Troubleshooting

**"Windows protected your PC" when running install.cmd**
Files downloaded from the internet are marked by Windows. Click **More info**, then **Run anyway**, or unblock the extracted folder in PowerShell: `Get-ChildItem -Path .\ai-cache-cleaner -Recurse | Unblock-File`.

**A row says "In use"**
Something is using that cache: an MCP server running from a uv environment, an open file in Temp, or a tool that's installing. Close it and click **Scan again**, or just leave it; it's retried next time.

**A row says "Skipped"**
Either you unticked it, or that tool isn't installed (for example no `pnpm` on your PATH).

**The weekly auto-clean switch is greyed out**
The app isn't installed yet (you opened the script directly). Run `install.cmd` first.

**Auto-clean didn't run**
It only runs while you're logged on. Check **Last auto-clean** in Settings and `clean.log`; errors from scheduled runs are written there too.

**Running inside a packaged AI desktop app**
If an agent installed the tool from inside a Microsoft Store style app, open a normal terminal and check that `%USERPROFILE%\.ai-cache-cleaner\oopSI - AI Cache Cleaner.exe` exists.

## 10. Uninstall

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.ai-cache-cleaner\ai-cache-cleaner.ps1" -Uninstall
```

This removes the install folder (including settings and log), the desktop shortcut, and the weekly task if you turned it on. Close the app first.

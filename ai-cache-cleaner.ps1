<#
oopSI - AI Cache Cleaner: frees disk space taken by regenerable AI / dev-tool caches on Windows:
uv (stale tool environments), npm, pnpm, pip, conda, old Temp files, Playwright browsers no project uses.
Models, venvs and conda envs are never deleted; the dry run lists them for you to review.

  .\ai-cache-cleaner.ps1                 dry run: show what can be freed, delete nothing
  .\ai-cache-cleaner.ps1 -Clean          clean now (skips caches unticked in the app)
  .\ai-cache-cleaner.ps1 -Gui            app window
  .\ai-cache-cleaner.ps1 -Install        install to %USERPROFILE%\.ai-cache-cleaner: app exe + desktop shortcut
  .\ai-cache-cleaner.ps1 -Schedule [-Day Sunday] [-Hour 13]   turn on the optional weekly auto-clean
  .\ai-cache-cleaner.ps1 -Unschedule     turn it off
  .\ai-cache-cleaner.ps1 -Uninstall      remove the app, shortcut, settings, log and weekly task
  .\ai-cache-cleaner.ps1 -Test           self-test in a throwaway folder under %TEMP%
#>
param([switch]$Clean, [switch]$AutoClean, [switch]$Gui, [switch]$Install, [switch]$Uninstall, [switch]$Test,
  [switch]$Schedule, [switch]$Unschedule,
  [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')][string]$Day = 'Sunday',
  [ValidateRange(0, 23)][int]$Hour = 13,
  [ValidateRange(1, 365)][int]$TempDays)   # default: settings.json, else 7

$Version = '2.0.2'
if (-not $HOME) { throw 'HOME is empty; refusing to run.' }
# ponytail: not under AppData - packaged (MSIX) apps get AppData writes silently redirected to a private copy
$AppDir = Join-Path $HOME '.ai-cache-cleaner'
$LogPath = Join-Path $AppDir 'clean.log'
$SettingsPath = Join-Path $AppDir 'settings.json'
$TaskName = 'AI Cache Cleaner'
$AppName = 'oopSI - AI Cache Cleaner'   # the desktop shortcut, the launcher exe and the window title
$ExeName = "$AppName.exe"
$OldName = 'AI Cache Cleaner'           # before 2.0.2; -Install and -Uninstall remove its shortcut and exe

# Everything from here to Invoke-Cleaner also runs in the app's background runspace: use $env: variables only, no script variables.

function Test-Link($Item) { [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) }

function Format-Size([double]$Bytes) {
  if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f ($Bytes / 1KB) }
}

function Get-Size([string]$Path) {
  $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $i) { return [int64]0 }
  if (-not $i.PSIsContainer) { return $i.Length }
  # robocopy /L lists without copying: fastest way to size big trees, and /XJ skips junctions.
  # Its summary labels are localized, so read the Total column of the third summary row (Dirs, Files, Bytes).
  $o = & "$env:SystemRoot\System32\robocopy.exe" $Path "$env:TEMP\__nul__" /L /S /NJH /BYTES /NFL /NDL /NC /NS /XJ /R:0 /W:0 /MT:16
  $sum = @($o | Where-Object { $_ -match ':\s+\d+(\s+\d+){5}\s*$' })
  if ($sum.Count -ge 3 -and $sum[2] -match ':\s+(\d+)') { [int64]$matches[1] } else { [int64]0 }
}

# Every file and folder under $Path. Links (junctions / symlinks) are listed but never entered.
function Get-Tree([string]$Path) {
  $stack = New-Object Collections.Stack
  $stack.Push((New-Object IO.DirectoryInfo $Path))
  while ($stack.Count) {
    $d = $stack.Pop()
    try { $kids = $d.GetFileSystemInfos() } catch { continue }
    foreach ($c in $kids) {
      $c
      if ($c -is [IO.DirectoryInfo] -and -not ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($c) }
    }
  }
}

# Deletes a file or folder tree. A link inside is removed as a link (its own .Delete()); its target is never touched.
# Never Remove-Item -Recurse (PS 5.1 can follow junctions) or cmd rd /s (cmd expands %VAR% in file names).
# ponytail: no \\?\ long-path support (PS 5.1 runs .NET with legacy path handling); anything past 260 chars stays put.
function Remove-Tree([string]$Path) {
  $root = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $root) { return }
  $all = @($root)
  if ($root.PSIsContainer -and -not (Test-Link $root)) { $all += @(Get-Tree $root.FullName) }
  [array]::Reverse($all)   # children before their parents
  foreach ($i in $all) {
    try {
      if (-not (Test-Link $i) -and ($i.Attributes -band [IO.FileAttributes]::ReadOnly)) {
        $i.Attributes = $i.Attributes -band -bnot [IO.FileAttributes]::ReadOnly
      }
      $i.Delete()
    } catch {}
  }
}

# Deletes $Path unless something in it is in use; returns whether it is gone. Links are skipped, never followed.
# Renaming a folder fails while any file inside is open, but succeeds while an exe runs from it, so loaded binaries are
# probed first: opening a loaded image for write fails (the probe writes nothing). The renamed <name>.aicc-del folder is
# then deleted; anything left of it is swept up on the next run.
function Remove-Safely([string]$Path) {
  $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $i -or (Test-Link $i)) { return $false }
  $del = $i.FullName
  if ($i.PSIsContainer) {
    foreach ($f in @(Get-Tree $del)) {
      if ($f -is [IO.FileInfo] -and $f.Extension -in '.exe', '.dll', '.pyd', '.node') {
        try { $f.Open('Open', 'Write', 'ReadWrite, Delete').Close() } catch { return $false }
      }
    }
    if ($del -notlike '*.aicc-del') {
      try { [IO.Directory]::Move($del, "$del.aicc-del") } catch { return $false }
      $del = "$del.aicc-del"
    }
  }
  Remove-Tree $del
  -not (Test-Path -LiteralPath $del)
}

# Folders a previous run renamed for deletion but couldn't finish.
function Get-Leftovers([string]$Root) {
  Get-ChildItem -LiteralPath $Root -Directory -Force -Filter '*.aicc-del' -ErrorAction SilentlyContinue | Where-Object { -not (Test-Link $_) } | ForEach-Object FullName
}

# Top-level items of a Temp folder untouched for $Days days, including everything inside them. Links are skipped.
function Get-OldItems([string]$Root, [int]$Days) {
  # A mis-set TEMP must never point this at real files: only a folder named Temp, and never the shared Windows\Temp
  # (an elevated run there could take other users' and services' files). Leftovers are swept only once these pass.
  $r = $Root.TrimEnd('\')
  if ([IO.Path]::GetFileName($r) -ne 'Temp' -or $r -eq "$env:SystemRoot\Temp") { return }
  $cut = (Get-Date).AddDays(-$Days)
  Get-ChildItem -LiteralPath $Root -Force -ErrorAction SilentlyContinue | Where-Object {
    -not (Test-Link $_) -and $_.LastWriteTime -lt $cut -and -not ($_.PSIsContainer -and
      (Get-Tree $_.FullName | Where-Object { $_.LastWriteTime -ge $cut } | Select-Object -First 1))
  } | ForEach-Object FullName
  Get-Leftovers $Root
}

# Playwright browser builds no installed Playwright needs. Every install registers its package in .links, and the builds
# each registered package's browsers.json names are kept. A registration whose package folder is gone belongs to a removed
# project (Playwright prunes those too). When unsure - no .links, an unreadable registration, a missing drive - select nothing.
function Get-PlaywrightStale([string]$Root) {
  $links = @(Get-ChildItem -LiteralPath (Join-Path $Root '.links') -File -Force -ErrorAction SilentlyContinue)
  if (-not $links) { return }
  $keep = @{}
  foreach ($l in $links) {
    try {
      $pkg = [IO.File]::ReadAllText($l.FullName, [Text.Encoding]::UTF8).Trim()
      if (-not [IO.Path]::IsPathRooted($pkg) -or -not (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($pkg)))) { return }
      if (-not (Test-Path -LiteralPath $pkg)) { continue }
      $browsers = @(([IO.File]::ReadAllText((Join-Path $pkg 'browsers.json')) | ConvertFrom-Json).browsers)
      if (-not $browsers) { return }
      foreach ($b in $browsers) {
        if (-not $b.name -or -not $b.revision) { return }
        $dir = $b.name -replace '-', '_'
        $keep["$dir-$($b.revision)"] = $true
        if ($b.revisionOverrides) { foreach ($o in $b.revisionOverrides.PSObject.Properties) { $keep["$dir-$($o.Value)"] = $true } }
      }
    } catch { return }
  }
  Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { $_.Name -match '^[a-z][a-z0-9_]*-\d+$' -and -not $keep[$_.Name] -and -not (Test-Link $_) } |
    ForEach-Object FullName
  Get-Leftovers $Root
}

# Every `uvx` / `uv run --with` leaves a cached environment behind (often 0.1-0.3 GB each, piling up by the hundred).
# `uv cache prune` deletes them all, including ones running MCP servers execute from, so this picks only real environments
# (pyvenv.cfg + Lib\site-packages) created over a day ago that no running process uses, plus their link files in
# environments-v*. uv recreates an environment the next time it is needed; Remove-Safely still probes each one first.
# ponytail: orphaned unpacked wheels are left alone (finding them means reading ~25k index files); `uv cache prune` gets those.
function Get-UvStale([string]$Cache, [string[]]$RunningPaths) {
  $arch = Join-Path $Cache 'archive-v0'
  if (-not (Test-Path -LiteralPath $arch)) { return }
  $inUse = @($RunningPaths | Where-Object { $_ -and $_.StartsWith("$arch\", 'OrdinalIgnoreCase') } | ForEach-Object { ($_.Substring($arch.Length + 1) -split '\\')[0] })
  $cut = (Get-Date).AddDays(-1)   # 1-day grace: a running `uv` may still be building a fresh one
  $stale = @(Get-ChildItem -LiteralPath $arch -Directory -Force | Where-Object {
      -not (Test-Link $_) -and $_.CreationTime -lt $cut -and $inUse -notcontains $_.Name -and
      (Test-Path -LiteralPath (Join-Path $_.FullName 'pyvenv.cfg')) -and (Test-Path -LiteralPath (Join-Path $_.FullName 'Lib\site-packages') -PathType Container)
    } | ForEach-Object Name)
  Get-ChildItem -LiteralPath $Cache -Directory -Force | Where-Object Name -match '^environments-v\d+$' | ForEach-Object { Get-Tree $_.FullName } |
    Where-Object { $_ -is [IO.FileInfo] -and $_.Length -lt 1KB -and
      (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match 'archive-v0/([\w-]+)' -and $stale -contains $matches[1] } |
    ForEach-Object FullName
  $stale | ForEach-Object { Join-Path $arch $_ }
  Get-Leftovers $arch
}

# Command lines that mean a tool is installing right now; its cache is left alone while one runs.
function Get-BusyPatterns {
  @{
    npm        = 'npm-cli\.js"?\s+(install|i|ci|add|update|uninstall|rebuild)\b'
    pnpm       = 'pnpm(\.cjs|\.mjs|\.exe|\.cmd)?"?\s+(install|i|add|update|up|remove|rm|store|dlx)\b'
    pip        = '\bpip(3(\.\d+)?)?(\.exe)?"?\s+(install|download|wheel)\b|-m\s+pip\s+(install|download|wheel)\b'
    conda      = '\b(conda|mamba)(\.exe|\.bat)?"?\s+(install|create|update|upgrade|remove|env)\b'
    playwright = 'playwright(\.cmd)?"?\s+install'
  }
}

# settings.json: { "skip": [target keys], "tempDays": 7 }. Unknown keys and out-of-range values are ignored.
function Get-Settings([string]$Path) {
  $s = @{ skip = @(); tempDays = 7 }
  try { $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json } catch { return $s }
  $s.skip = @($j.skip | Where-Object { $_ -is [string] -and $_ -in 'uv', 'npm', 'pnpm', 'pip', 'conda', 'temp', 'playwright' } | ForEach-Object { $_.ToLower() } | Select-Object -Unique)
  if ($j.tempDays -is [int] -and $j.tempDays -ge 1 -and $j.tempDays -le 365) { $s.tempDays = $j.tempDays }
  $s
}

function Save-Settings([string]$Path, $Settings) {
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
  [IO.File]::WriteAllText($Path, (@{ skip = @($Settings.skip); tempDays = [int]$Settings.tempDays } | ConvertTo-Json))
}

# clean.log: 'yyyy-MM-dd HH:mm  freed X.XX GB  items N  manual|auto' (invariant culture). v1 lines only had 'freed X GB'.
function Write-LogLine([string]$Path, [int64]$Bytes, [int]$Items, [string]$Mode) {
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
  [IO.File]::AppendAllText($Path, [string]::Format([cultureinfo]::InvariantCulture, "{0:yyyy-MM-dd HH:mm}  freed {1:0.00} GB  items {2}  {3}`r`n", (Get-Date), $Bytes / 1GB, $Items, $Mode))
}

function Read-Log([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return }
  foreach ($l in [IO.File]::ReadAllLines($Path)) {
    if ($l -match '^(\d{4}-\d\d-\d\d \d\d:\d\d)\s+freed ([\d.]+) GB(?:\s+items (\d+))?(?:\s+(manual|auto))?') {
      try {   # a damaged line (impossible date, '1.2.3') is skipped, not a reason for the app to crash
        [pscustomobject]@{ Date = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture)
          FreedGB = [double]::Parse($matches[2], [cultureinfo]::InvariantCulture); Items = $matches[3]; Mode = $matches[4] }
      } catch {}
    }
  }
}

# Scans every target and, with $Clean, cleans the ones not in $Skip. $Report receives progress events for the app window.
function Invoke-Cleaner([bool]$Clean, [int]$TempDays, [string[]]$Skip, [string]$LogPath, [string]$Mode = 'manual', [scriptblock]$Report = {}) {
  # Every target path is built from these; an empty one would turn "$env:LOCALAPPDATA\npm-cache" into a path off the drive root.
  foreach ($v in 'SystemRoot', 'LOCALAPPDATA', 'USERPROFILE', 'TEMP') {
    if (-not [IO.Path]::IsPathRooted([Environment]::GetEnvironmentVariable($v))) { throw "$v is not set; refusing to run." }
  }
  $mutex = $null
  if ($Clean) {
    # One cleanup at a time (app, command line and weekly task). A mutex left behind by a crashed run counts as ours.
    $mutex = New-Object Threading.Mutex($false, 'Local\AiCacheCleaner')
    try { $owned = $mutex.WaitOne(0) } catch { $owned = $_.Exception.GetBaseException() -is [Threading.AbandonedMutexException] }
    if (-not $owned) { $mutex.Dispose(); & $Report @{ Log = 'skipped: another cleanup is already running' }; return }
  }
  Push-Location -LiteralPath $env:SystemRoot   # relative PATH entries now resolve under Windows, not wherever we started
  try {
    $L = $env:LOCALAPPDATA; $U = $env:USERPROFILE
    $conda = @($env:CONDA_EXE, "$env:ProgramData\miniconda3\Scripts\conda.exe", "$env:ProgramData\anaconda3\Scripts\conda.exe",
      "$U\miniconda3\Scripts\conda.exe", "$U\anaconda3\Scripts\conda.exe") | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    # ponytail: only package dirs under the profile; a machine-wide install's pkgs needs admin, so conda can't clean it as you
    $condaPkgs = @("$U\.conda\pkgs"; if ($conda) { Join-Path (Split-Path (Split-Path $conda)) 'pkgs' }) |
      Where-Object { $_.StartsWith("$U\", 'OrdinalIgnoreCase') } | Select-Object -Unique
    $targets = @(
      @{ Key = 'uv'; Name = 'uv: stale tool environments'; Paths = { Get-UvStale "$L\uv\cache" $running } }
      @{ Key = 'npm'; Name = 'npm package cache'; Paths = { "$L\npm-cache\_cacache" }; Exe = 'npm'; Args = 'cache', 'clean', '--force' }
      @{ Key = 'pnpm'; Name = 'pnpm store (unused packages)'; Paths = { "$L\pnpm\store" }; Exe = 'pnpm'; Args = 'store', 'prune' }
      @{ Key = 'pip'; Name = 'pip cache'; Paths = { "$L\pip\cache" }; Exe = 'pip'; Args = 'cache', 'purge' }
      @{ Key = 'conda'; Name = 'conda package cache'; Exe = $conda; Args = 'clean', '--tarballs', '--index-cache', '--logfiles', '-y'
        Paths = { foreach ($d in $condaPkgs) { Get-ChildItem -LiteralPath $d -File -Force -ErrorAction SilentlyContinue | Where-Object Name -match '\.(conda|tar\.bz2)$' | ForEach-Object FullName; "$d\cache" } } }
      @{ Key = 'temp'; Name = "Temp files untouched $TempDays+ days"; Paths = { Get-OldItems $env:TEMP $TempDays | Select-Object -Unique } }
      @{ Key = 'playwright'; Name = 'Playwright browsers no project uses'; Paths = { Get-PlaywrightStale "$L\ms-playwright" } }
    )
    $n = $targets.Count; $total = [int64]0; $count = 0
    & $Report @{ Targets = @($targets | ForEach-Object { @{ Key = $_.Key; Name = $_.Name } }) }
    # One process snapshot: exe paths for uv's in-use check, command lines for the busy guards.
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $running = @($procs | ForEach-Object ExecutablePath | Where-Object { $_ })
    $cmdLines = @($procs | ForEach-Object CommandLine | Where-Object { $_ })
    $busy = Get-BusyPatterns
    for ($i = 0; $i -lt $n; $i++) {
      $t = $targets[$i]; $isTool = $t.ContainsKey('Exe')
      & $Report @{ I = $i; Status = 'Scanning'; P = $i / $n }
      $paths = @(& $t.Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
      $sizes = New-Object 'Collections.Generic.List[int64]'
      foreach ($p in $paths) {
        $sizes.Add((Get-Size $p))
        if ($sizes.Count % 10 -eq 0) { & $Report @{ P = ($i + 0.5 * $sizes.Count / $paths.Count) / $n } }
      }
      $before = [int64]($sizes | Measure-Object -Sum).Sum
      $freed = [int64]0; $note = ''
      $status = if ($before) { 'Found' } else { 'Nothing found' }
      if ($Clean -and $before) {
        if ($Skip -contains $t.Key) { $status = 'Skipped'; $note = 'unticked in the app' }
        elseif ($busy[$t.Key] -and @($cmdLines -match $busy[$t.Key]).Count) { $status = 'In use'; $note = "$($t.Key) is installing something right now" }
        elseif ($isTool) {
          & $Report @{ I = $i; Status = 'Cleaning'; P = ($i + 0.5) / $n }
          $exe = if ($t.Exe) { Get-Command $t.Exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source }
          if ($exe -and [IO.Path]::IsPathRooted($exe) -and -not $exe.StartsWith("$env:TEMP\", 'OrdinalIgnoreCase') -and $exe -notlike '*\Temp\*') {
            & $exe @($t.Args) *>&1 | Out-Null
            $after = [int64](@($paths | ForEach-Object { Get-Size $_ }) | Measure-Object -Sum).Sum
            $freed = [math]::Max([int64]0, $before - $after); $count++; $status = 'Cleaned'
            & $Report @{ Log = 'ran      {0,8}  {1} {2}' -f (Format-Size $freed), $t.Key, ($t.Args -join ' ') }
          } else { $status = 'Skipped'; $note = "$($t.Key) is not installed (or sits in a Temp folder)" }
        } else {
          & $Report @{ I = $i; Status = 'Cleaning'; P = ($i + 0.5) / $n }
          $gone = 0
          for ($k = 0; $k -lt $paths.Count; $k++) {
            $ok = Remove-Safely $paths[$k]
            if ($ok) { $freed += $sizes[$k]; $gone++ }
            & $Report @{ Log = '{0}  {1,8}  {2}' -f $(if ($ok) { 'removed' } else { 'in use ' }), (Format-Size $sizes[$k]), $paths[$k]
              P = ($i + 0.5 + 0.5 * ($k + 1) / $paths.Count) / $n }
          }
          $count += $gone
          $status = if ($gone) { 'Cleaned' } else { 'In use' }
          if ($gone -lt $paths.Count) { $note = '{0} of {1} items in use; tried again next run' -f ($paths.Count - $gone), $paths.Count }
        }
      }
      $total += $freed
      $row = [pscustomobject]@{ Key = $t.Key; Target = $t.Name; Status = $status; Items = $(if ($isTool) { '-' } else { $paths.Count })
        SizeGB = [math]::Round($before / 1GB, 2); FreedGB = [math]::Round($freed / 1GB, 2); Bytes = $before; FreedBytes = $freed; Note = $note
        Command = $(if ($isTool) { "$($t.Key) $($t.Args -join ' ')" })
        Details = @(@(for ($k = 0; $k -lt $paths.Count; $k++) { [pscustomobject]@{ Path = $paths[$k]; Bytes = $sizes[$k] } }) | Sort-Object Bytes -Descending) }
      & $Report @{ I = $i; Row = $row; P = ($i + 1) / $n }
      $row
    }
    if ($Clean) { Write-LogLine $LogPath $total $count $Mode }
  } finally {
    Pop-Location
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
  }
}

# --- Weekly auto-clean (optional, off by default). Runs as the current user, only while logged on, without admin rights.

function Set-Schedule([string]$Day, [int]$Hour) {
  $exe = Join-Path $AppDir $ExeName
  if (-not (Test-Path -LiteralPath $exe)) { throw "Install the app first (-Install): $exe is missing." }
  $p = @{
    Action    = New-ScheduledTaskAction -Execute $exe -Argument '-AutoClean' -WorkingDirectory $AppDir
    Trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At ([datetime]::Today.AddHours($Hour))
    Settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
  }
  Register-ScheduledTask -TaskName $TaskName @p -Description 'Optional weekly AI Cache Cleaner run. Turn it off in the app''s Settings.' -Force | Out-Null
}

function Remove-Schedule { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }

# The enabled weekly task as @{ Day; Hour; Next }, or nothing.
function Get-Schedule {
  $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t -or $t.State -eq 'Disabled') { return }
  $tr = @($t.Triggers)[0]
  $d = if ($tr.DaysOfWeek) { [string][DayOfWeek](0..6 | Where-Object { $tr.DaysOfWeek -band (1 -shl $_) } | Select-Object -First 1) } else { 'Sunday' }
  $h = if ($tr.StartBoundary -match 'T(\d\d):') { [int]$matches[1] } else { 13 }
  @{ Day = $d; Hour = $h; Next = (Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue).NextRunTime }
}

if ($Test) {
  $t = Join-Path $env:TEMP "aicc-test-$PID"
  $file = { param($p, $age = 0, $text = 'x')
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)); [IO.File]::WriteAllText($p, $text)
    $f = New-Object IO.FileInfo $p; $f.CreationTime = $f.LastWriteTime = (Get-Date).AddDays(-$age) }
  $dir = { param($p, $age = 0) $d = [IO.Directory]::CreateDirectory($p); $d.CreationTime = $d.LastWriteTime = (Get-Date).AddDays(-$age) }
  $check = { param($what, $ok) if (-not $ok) { throw "self-test failed: $what" } }
  $expect = { param($what, $got, [string[]]$want)
    $g = (@($got | Where-Object { $_ }) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object) -join ','
    $e = (@($want) | Sort-Object) -join ','
    if ($g -ne $e) { throw "self-test failed: $what selected '$g', expected '$e'" } }
  $open = $null; $ping = $null
  try {
    # Deleting: links are removed as links, never followed; anything in use is skipped and keeps its name.
    & $file "$t\keep\precious.txt"
    New-Item -ItemType Junction -Path "$t\top link" -Target "$t\keep" | Out-Null
    & $check 'a top-level junction is left alone' (-not (Remove-Safely "$t\top link") -and (Test-Path -LiteralPath "$t\top link") -and (Test-Path -LiteralPath "$t\keep\precious.txt"))
    & $file "$t\del me\sub\f.txt"
    New-Item -ItemType Junction -Path "$t\del me\link" -Target "$t\keep" | Out-Null
    & $check 'a nested junction''s target survives' ((Remove-Safely "$t\del me") -and -not (Test-Path -LiteralPath "$t\del me") -and (Test-Path -LiteralPath "$t\keep\precious.txt"))
    & $file "$t\ro\sub\a.txt"; (Get-Item -LiteralPath "$t\ro\sub\a.txt").IsReadOnly = $true; (Get-Item -LiteralPath "$t\ro\sub").Attributes = 'Directory, ReadOnly'
    Remove-Tree "$t\ro"
    & $check 'read-only files are deleted' (-not (Test-Path -LiteralPath "$t\ro"))
    & $file "$t\odd %PATH% & x\a %PATH% & b.txt"
    & $check 'names with %PATH%, & and spaces are deleted' ((Remove-Safely "$t\odd %PATH% & x") -and -not (Test-Path -LiteralPath "$t\odd %PATH% & x"))
    & $file "$t\open\f.txt"; $open = [IO.File]::Open("$t\open\f.txt", 'Open', 'Read', 'Read')
    & $check 'a folder with an open file is skipped and keeps its name' (-not (Remove-Safely "$t\open") -and (Test-Path -LiteralPath "$t\open\f.txt") -and -not (Test-Path -LiteralPath "$t\open.aicc-del"))
    $open.Close()
    [void][IO.Directory]::CreateDirectory("$t\run"); Copy-Item -LiteralPath "$env:SystemRoot\System32\PING.EXE" -Destination "$t\run\PING.EXE"
    $ping = Start-Process -FilePath "$t\run\PING.EXE" -ArgumentList '-n 3 127.0.0.1' -WindowStyle Hidden -PassThru
    & $check 'the test exe is running' (-not $ping.HasExited)
    & $check 'a folder with a running exe is skipped' (-not (Remove-Safely "$t\run") -and (Test-Path -LiteralPath "$t\run\PING.EXE") -and -not (Test-Path -LiteralPath "$t\run.aicc-del"))
    $ping.WaitForExit()

    # Playwright: keep every build a registered package names; registrations are UTF-8 and real paths hold non-ASCII.
    $pw = "$t\pw"; $pkg = "$t\proj $([char]0x200E) x\package"
    & $file "$pkg\browsers.json" 0 '{"browsers":[{"name":"chromium","revision":"1200"},{"name":"chromium-headless-shell","revision":"1200"},{"name":"webkit","revision":"2248","revisionOverrides":{"mac12":"2009"}}]}'
    & $file "$pw\.links\aaaa" 0 $pkg
    & $file "$pw\.links\bbbb" 0 "$t\removed project\package"
    'chromium-1181', 'chromium-1200', 'chromium_headless_shell-1181', 'chromium_headless_shell-1200', 'webkit-2248', 'webkit-2009', 'ffmpeg-1011', 'chromium-1100.aicc-del' |
      ForEach-Object { & $dir "$pw\$_" }
    & $expect 'playwright' (Get-PlaywrightStale $pw) 'chromium-1181', 'chromium_headless_shell-1181', 'ffmpeg-1011', 'chromium-1100.aicc-del'
    [IO.File]::WriteAllText("$pkg\browsers.json", '{ not json')
    & $expect 'playwright with an unreadable registration' (Get-PlaywrightStale $pw) @()
    Remove-Tree "$pw\.links"
    & $expect 'playwright without .links' (Get-PlaywrightStale $pw) @()

    # uv: envs A (running), B (idle, linked), X (idle, unlinked), F (fresh), N (no site-packages); W is an unpacked wheel
    $u = "$t\uv"
    foreach ($e in 'A', 'B', 'X', 'N') {
      & $file "$u\archive-v0\$e\pyvenv.cfg"; if ($e -ne 'N') { & $dir "$u\archive-v0\$e\Lib\site-packages" }; & $dir "$u\archive-v0\$e" 5 }
    & $file "$u\archive-v0\F\pyvenv.cfg"; & $dir "$u\archive-v0\F\Lib\site-packages"; & $dir "$u\archive-v0\F" 0
    & $file "$u\archive-v0\W\pkg.dist-info\METADATA"; & $dir "$u\archive-v0\W" 5
    & $file "$u\environments-v2\g\aaaaaaaaaaaaaaaa" 5 'archive-v0/A'
    & $file "$u\environments-v2\g\bbbbbbbbbbbbbbbb" 5 'archive-v0/B'
    & $file "$u\environments-v2\g\ffffffffffffffff" 5 'archive-v0/F'
    & $expect 'uv' (Get-UvStale $u @("$u\archive-v0\A\Scripts\python.exe")) 'B', 'bbbbbbbbbbbbbbbb', 'X'

    # Temp: whole items untouched for N days; only in a folder named Temp; links skipped
    $tp = "$t\Temp"
    & $file "$tp\busy\new.txt" 0; & $dir "$tp\busy" 9      # old dir, fresh file inside -> keep
    & $file "$tp\stale\old.txt" 9; & $dir "$tp\stale" 9    # everything old -> clean
    & $file "$tp\old.txt" 9; & $file "$tp\new.txt" 0
    & $dir "$tp\left.aicc-del" 0                            # a fresh leftover from an unfinished run -> clean
    & $expect 'temp' (Get-OldItems $tp 7) 'old.txt', 'stale', 'left.aicc-del'
    & $file "$t\NotTemp\old.txt" 9; & $dir "$t\NotTemp\left.aicc-del" 0
    & $expect 'temp outside a folder named Temp' (Get-OldItems "$t\NotTemp" 7) @()
    & $expect 'temp under Windows' (Get-OldItems "$env:SystemRoot\Temp\" 0) @()
    & $dir "$t\links\Temp\real" 1; New-Item -ItemType Junction -Path "$t\links\Temp\link" -Target "$t\keep" | Out-Null
    & $expect 'temp with a junction' (Get-OldItems "$t\links\Temp" 0) 'real'

    # Busy guards
    $bp = Get-BusyPatterns
    @(@('npm', '"C:\Program Files\nodejs\node.exe" "C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js" install', $true),
      @('npm', '"C:\Program Files\nodejs\node.exe" "C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js" run build', $false),
      @('pnpm', 'node "C:\x\node_modules\pnpm\bin\pnpm.cjs" add left-pad', $true), @('pnpm', 'pnpm.exe run dev', $false),
      @('pip', 'python.exe -m pip install requests', $true), @('pip', '"C:\Python311\Scripts\pip3.11.exe" download x', $true), @('pip', 'pip list', $false),
      @('conda', 'conda.exe create -n x python', $true), @('conda', 'conda.exe clean --tarballs -y', $false),
      @('playwright', 'node playwright.cmd install chromium', $true), @('playwright', 'npx playwright test', $false)) |
      ForEach-Object { & $check "busy guard $($_[0]): $($_[1])" (($_[1] -match $bp[$_[0]]) -eq $_[2]) }

    # Settings and log
    $sp = "$t\settings.json"
    [IO.File]::WriteAllText($sp, '{"skip":["npm","rm -rf","temp"],"tempDays":500,"extra":1}'); $s = Get-Settings $sp
    & $check 'settings ignore unknown keys and out-of-range days' (((@($s.skip) | Sort-Object) -join ',') -eq 'npm,temp' -and $s.tempDays -eq 7)
    [IO.File]::WriteAllText($sp, 'garbage'); $s = Get-Settings $sp
    & $check 'unreadable settings give defaults' ($s.tempDays -eq 7 -and -not $s.skip)
    Save-Settings $sp @{ skip = @('pip'); tempDays = 14 }; $s = Get-Settings $sp
    & $check 'settings round-trip' ((@($s.skip) -join ',') -eq 'pip' -and $s.tempDays -eq 14)
    $lp = "$t\clean.log"
    [IO.File]::WriteAllLines($lp, [string[]]@('2026-01-04 13:00  freed 1.50 GB', 'garbage', '2026-13-45 13:00  freed 9.99 GB'))
    Write-LogLine $lp ([int64](0.25 * 1GB)) 12 'auto'
    $runs = @(Read-Log $lp)
    & $check 'log reads v1 and v2 lines' ($runs.Count -eq 2 -and $runs[0].Date.Hour -eq 13 -and $runs[1].Mode -eq 'auto' -and $runs[1].Items -eq '12' -and
      [math]::Abs(($runs | Measure-Object FreedGB -Sum).Sum - 1.75) -lt 0.001)
  } finally {
    if ($open) { $open.Close() }
    if ($ping) { $ping.WaitForExit() }
    Remove-Tree $t
  }
  if (Test-Path -LiteralPath $t) { throw "self-test: could not clean up $t" }
  'self-test passed'; return
}

if ($Uninstall) {
  if ([IO.Path]::GetFileName($AppDir) -ne '.ai-cache-cleaner') { throw "Refusing to remove unexpected folder $AppDir" }
  Remove-Schedule
  foreach ($n in $AppName, $OldName) { Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) "$n.lnk") -Force -ErrorAction SilentlyContinue }
  Remove-Tree $AppDir
  if (Test-Path -LiteralPath $AppDir) { "Uninstalled, but some files in $AppDir are in use (is the app open?). Close it and run -Uninstall again." } else { 'Uninstalled.' }
  return
}

if ($Install) {
  New-Item -ItemType Directory $AppDir -Force | Out-Null
  $dst = Join-Path $AppDir 'ai-cache-cleaner.ps1'
  if ($PSCommandPath -ne $dst) { Copy-Item -LiteralPath $PSCommandPath -Destination $dst -Force }
  $exe = Join-Path $AppDir $ExeName; $ico = Join-Path $AppDir 'app.ico'
  if ($PSScriptRoot -ne $AppDir) {   # the logo, icon and bundled font travel with the script
    foreach ($f in 'logo.png', 'app.ico') { if (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f)) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $AppDir -Force } }
    $fonts = Join-Path $PSScriptRoot 'fonts'
    if (Test-Path -LiteralPath $fonts) {
      New-Item -ItemType Directory (Join-Path $AppDir 'fonts') -Force | Out-Null
      Get-ChildItem -LiteralPath $fonts -File | Copy-Item -Destination (Join-Path $AppDir 'fonts') -Force
    }
  }
  if (-not (Test-Path -LiteralPath $ico)) {   # run as a lone script: borrow the Disk Cleanup icon
    Add-Type -AssemblyName System.Drawing
    try { $fs = [IO.File]::Create($ico); [Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\cleanmgr.exe").Save($fs) } catch {} finally { if ($fs) { $fs.Close() } }
  }
  # Tiny launcher compiled with the C# compiler built into Windows: no console window. It starts Windows PowerShell by
  # absolute path, passes through only -AutoClean (anything else opens the app) and runs from the app folder.
  $cp = New-Object CodeDom.Compiler.CompilerParameters
  $cp.GenerateExecutable = $true; $cp.OutputAssembly = $exe; [void]$cp.ReferencedAssemblies.Add('System.dll')
  $cp.CompilerOptions = '/target:winexe' + $(if ((Get-Item -LiteralPath $ico -ErrorAction SilentlyContinue).Length) { " /win32icon:`"$ico`"" })
  Remove-Item -LiteralPath $exe -Force -ErrorAction SilentlyContinue
  Add-Type -CompilerParameters $cp -TypeDefinition @'
using System; using System.Diagnostics; using System.IO;
public static class Launcher {
  public static void Main(string[] args) {
    string dir = Path.GetDirectoryName(typeof(Launcher).Assembly.Location);
    string ps = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
    bool auto = args.Length == 1 && args[0] == "-AutoClean";
    ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \""
      + Path.Combine(dir, "ai-cache-cleaner.ps1") + "\" " + (auto ? "-AutoClean" : "-Gui"));
    psi.UseShellExecute = false; psi.CreateNoWindow = true; psi.WorkingDirectory = dir;
    Process p = Process.Start(psi);
    if (auto) p.WaitForExit();
  }
}
'@
  # the names before 2.0.2 go: their shortcut and launcher (a task from then is re-pointed at the new exe below)
  Remove-Item -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) "$OldName.lnk"), (Join-Path $AppDir "$OldName.exe") -Force -ErrorAction SilentlyContinue
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) "$AppName.lnk"))
  $lnk.TargetPath = $exe; $lnk.WorkingDirectory = $AppDir; $lnk.Description = 'Free disk space from AI / dev-tool caches'; $lnk.Save()
  "Installed to $AppDir"
  "  app:      $exe (desktop shortcut '$AppName')"
  # A task from an earlier version: an enabled one keeps its day and hour with the new -AutoClean action; a disabled one goes.
  $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($old -and $old.State -ne 'Disabled') { $s = Get-Schedule; Set-Schedule $s.Day $s.Hour; '  schedule: weekly auto-clean kept, {0} {1:00}:00' -f $s.Day, $s.Hour }
  elseif ($old) { Remove-Schedule; '  schedule: off (removed a disabled task from an earlier version)' }
  else { '  schedule: off (turn on weekly auto-clean in the app''s Settings, or run with -Schedule)' }
  return
}

if ($Schedule) { Set-Schedule $Day $Hour; 'Weekly auto-clean on: {0} {1:00}:00' -f $Day, $Hour; return }
if ($Unschedule) { Remove-Schedule; 'Weekly auto-clean off.'; return }

if ($AutoClean) {
  $s = Get-Settings $SettingsPath
  try { Invoke-Cleaner $true $s.tempDays $s.skip $LogPath 'auto' | Out-Null }
  catch { [IO.File]::AppendAllText($LogPath, [string]::Format([cultureinfo]::InvariantCulture, "{0:yyyy-MM-dd HH:mm}  error  {1}  auto`r`n", (Get-Date), $_)) }
  return
}

if ($Gui) {
  Add-Type -AssemblyName PresentationFramework, System.Drawing
  # A row of the cache table. Bound properties notify the window, so updating a row keeps its tick and expanded state.
  Add-Type -TypeDefinition @'
using System.ComponentModel;
public class CacheRow : INotifyPropertyChanged {
  public event PropertyChangedEventHandler PropertyChanged;
  void Set<T>(ref T field, T value, string name) {
    field = value;
    PropertyChangedEventHandler h = PropertyChanged;
    if (h != null) h(this, new PropertyChangedEventArgs(name));
  }
  string key, name, badge, color, status, items, size, freed, details; bool selected, expanded; long bytes, freedBytes;
  public string Key { get { return key; } set { Set(ref key, value, "Key"); } }
  public string Name { get { return name; } set { Set(ref name, value, "Name"); } }
  public string Badge { get { return badge; } set { Set(ref badge, value, "Badge"); } }
  public string Color { get { return color; } set { Set(ref color, value, "Color"); } }
  public string Status { get { return status; } set { Set(ref status, value, "Status"); } }
  public string Items { get { return items; } set { Set(ref items, value, "Items"); } }
  public string Size { get { return size; } set { Set(ref size, value, "Size"); } }
  public string Freed { get { return freed; } set { Set(ref freed, value, "Freed"); } }
  public string Details { get { return details; } set { Set(ref details, value, "Details"); } }
  public bool Selected { get { return selected; } set { Set(ref selected, value, "Selected"); } }
  public bool Expanded { get { return expanded; } set { Set(ref expanded, value, "Expanded"); } }
  public long Bytes { get { return bytes; } set { Set(ref bytes, value, "Bytes"); } }
  public long FreedBytes { get { return freedBytes; } set { Set(ref freedBytes, value, "FreedBytes"); } }
}
'@
  [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="oopSI - AI Cache Cleaner" Width="1320" Height="1000" MinWidth="1080" MinHeight="640" WindowStartupLocation="CenterScreen"
        FontFamily="{DynamicResource Body}" FontSize="14" Foreground="#111827" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Ideal" TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <BooleanToVisibilityConverter x:Key="Vis"/>
    <FontFamily x:Key="Icons">Segoe Fluent Icons, Segoe MDL2 Assets</FontFamily>
    <!-- Replaced by the bundled Inter (fonts\) at startup; these are the fallbacks. -->
    <FontFamily x:Key="Body">Segoe UI Variable Text, Segoe UI</FontFamily>
    <FontFamily x:Key="Display">Segoe UI Variable Display, Segoe UI</FontFamily>
    <LinearGradientBrush x:Key="Dark" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#3A3F47" Offset="0"/><GradientStop Color="#1F2329" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="Blue" StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#5B8DEF" Offset="0"/><GradientStop Color="#2F6FE4" Offset="1"/></LinearGradientBrush>
    <LinearGradientBrush x:Key="TileBg" StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#FFFFFFFF" Offset="0"/><GradientStop Color="#FFEDEFF3" Offset="1"/></LinearGradientBrush>
    <RadialGradientBrush x:Key="Blob"><GradientStop Color="#F2FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/></RadialGradientBrush>
    <RadialGradientBrush x:Key="BlobGrey"><GradientStop Color="#40A3ABB8" Offset="0"/><GradientStop Color="#00A3ABB8" Offset="1"/></RadialGradientBrush>

    <Style x:Key="Focus"><Setter Property="Control.Template"><Setter.Value><ControlTemplate>
      <Border BorderBrush="#995B8DEF" BorderThickness="2" CornerRadius="14" Margin="-3"/>
    </ControlTemplate></Setter.Value></Setter></Style>
    <Style x:Key="Glass" TargetType="ContentControl">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContentControl">
        <Grid>
          <Border Background="#A6FFFFFF" BorderBrush="#CCFFFFFF" BorderThickness="1" CornerRadius="24">
            <Border.Effect><DropShadowEffect BlurRadius="40" ShadowDepth="10" Direction="270" Opacity="0.10" Color="#1F2937"/></Border.Effect>
          </Border>
          <ContentPresenter Margin="{TemplateBinding Padding}"/>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Card" TargetType="ContentControl">
      <Setter Property="Padding" Value="22,20"/><Setter Property="Margin" Value="0,0,0,18"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContentControl">
        <Grid>
          <Border Background="#B3FFFFFF" BorderBrush="#CCFFFFFF" BorderThickness="1" CornerRadius="16">
            <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="6" Direction="270" Opacity="0.07" Color="#1F2937"/></Border.Effect>
          </Border>
          <ContentPresenter Margin="{TemplateBinding Padding}"/>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Tile" TargetType="ContentControl">
      <Setter Property="Width" Value="54"/><Setter Property="Height" Value="54"/><Setter Property="FontSize" Value="22"/>
      <Setter Property="FontFamily" Value="{StaticResource Icons}"/><Setter Property="Foreground" Value="#374151"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ContentControl">
        <Border Background="{StaticResource TileBg}" BorderBrush="#E8EAEE" BorderThickness="1" CornerRadius="14">
          <Border.Effect><DropShadowEffect BlurRadius="12" ShadowDepth="2" Direction="270" Opacity="0.08"/></Border.Effect>
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#111827"/><Setter Property="Background" Value="#E6FFFFFF"/><Setter Property="BorderBrush" Value="#E5E7EB"/>
      <Setter Property="Padding" Value="18,10"/><Setter Property="Margin" Value="12,0,0,0"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource Focus}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="{TemplateBinding Padding}">
          <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="3" Direction="270" Opacity="0.10"/></Border.Effect>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <TextBlock x:Name="g" Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource Icons}" FontSize="16" Margin="0,0,12,0" VerticalAlignment="Center"/>
            <ContentPresenter VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="Tag" Value="{x:Null}"><Setter TargetName="g" Property="Visibility" Value="Collapsed"/></Trigger>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.72"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Dark}"/><Setter Property="Foreground" Value="White"/><Setter Property="BorderBrush" Value="#1F2329"/>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#111827"/><Setter Property="FontSize" Value="15"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <StackPanel x:Name="b" Orientation="Horizontal" Background="Transparent">
          <ContentPresenter VerticalAlignment="Center"/>
          <TextBlock Text="&#xE72A;" FontFamily="{StaticResource Icons}" FontSize="14" Margin="12,1,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#4B5563"/><Setter Property="FontSize" Value="14.5"/><Setter Property="Margin" Value="0,0,0,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="GroupName" Value="nav"/><Setter Property="FocusVisualStyle" Value="{StaticResource Focus}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="14" Padding="16,13">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="{Binding Tag, RelativeSource={RelativeSource TemplatedParent}}" FontFamily="{StaticResource Icons}" FontSize="18" Width="22" Margin="0,0,16,0" VerticalAlignment="Center"/>
            <ContentPresenter VerticalAlignment="Center"/>
          </StackPanel>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#59FFFFFF"/></Trigger>
          <Trigger Property="IsChecked" Value="True">
            <Setter TargetName="b" Property="Background" Value="#E6FFFFFF"/><Setter TargetName="b" Property="BorderBrush" Value="#FFFFFFFF"/>
            <Setter TargetName="b" Property="Effect"><Setter.Value><DropShadowEffect BlurRadius="16" ShadowDepth="3" Direction="270" Opacity="0.10"/></Setter.Value></Setter>
            <Setter Property="Foreground" Value="#111827"/><Setter Property="FontWeight" Value="SemiBold"/>
          </Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <Border x:Name="box" Width="18" Height="18" CornerRadius="5" Background="#F2FFFFFF" BorderBrush="#9CA3AF" BorderThickness="1.5">
          <TextBlock x:Name="mark" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="box" Property="BorderBrush" Value="#4B5563"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="box" Property="Background" Value="#1F2329"/><Setter TargetName="box" Property="BorderBrush" Value="#1F2329"/><Setter TargetName="mark" Property="Text" Value="&#xE73E;"/></Trigger>
          <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="box" Property="Background" Value="#1F2329"/><Setter TargetName="box" Property="BorderBrush" Value="#1F2329"/><Setter TargetName="mark" Property="Text" Value="&#xE738;"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <Border x:Name="track" Width="48" Height="27" CornerRadius="13.5" Background="#D1D5DB">
          <Border x:Name="thumb" Width="21" Height="21" CornerRadius="10.5" Background="White" HorizontalAlignment="Left" Margin="3,0">
            <Border.Effect><DropShadowEffect BlurRadius="4" ShadowDepth="1" Direction="270" Opacity="0.25"/></Border.Effect>
          </Border>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="track" Property="Background" Value="{StaticResource Blue}"/><Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter TargetName="track" Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Chevron" TargetType="ToggleButton">
      <Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ToggleButton">
        <Border x:Name="b" Background="Transparent" Width="32" Height="32" CornerRadius="8">
          <TextBlock x:Name="c" Text="&#xE76C;" FontFamily="{StaticResource Icons}" FontSize="12" Foreground="#4B5563" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#99FFFFFF"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="c" Property="RenderTransform"><Setter.Value><RotateTransform Angle="90"/></Setter.Value></Setter></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="38"/><Setter Property="Width" Value="170"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBox">
        <Grid>
          <ToggleButton Focusable="False" ClickMode="Press" IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
            <ToggleButton.Template><ControlTemplate TargetType="ToggleButton">
              <Border x:Name="b" Background="#E6FFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="10">
                <TextBlock Text="&#xE70D;" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="#6B7280" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,14,0"/>
              </Border>
              <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#9CA3AF"/></Trigger></ControlTemplate.Triggers>
            </ControlTemplate></ToggleButton.Template>
          </ToggleButton>
          <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" Margin="14,0,36,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
          <Popup x:Name="PART_Popup" IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}" Placement="Bottom" AllowsTransparency="True" Focusable="False">
            <Border Background="White" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="10" Margin="0,4,8,8" Padding="4" MaxHeight="300"
                    MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
              <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="3" Direction="270" Opacity="0.12"/></Border.Effect>
              <ScrollViewer><ItemsPresenter/></ScrollViewer>
            </Border>
          </Popup>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ComboBoxItem">
        <Border x:Name="b" Padding="10,7" CornerRadius="6" Background="Transparent"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="#E5E7EB"/></Trigger>
          <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="b" Property="Background" Value="#F3F4F6"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="10"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ProgressBar">
        <Grid>
          <Border x:Name="PART_Track" Background="#E3E6EB" CornerRadius="5"/>
          <Border x:Name="PART_Indicator" Background="{StaticResource Blue}" CornerRadius="5" HorizontalAlignment="Left"/>
        </Grid>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True">
          <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#33111827" CornerRadius="4"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
        </Track>
      </ControlTemplate></Setter.Value></Setter>
    </Style>

    <!-- Caps labels get Inter's capital spacing (WPF has no letter-spacing); numbers use tabular figures so columns line up. -->
    <Style x:Key="Cap" TargetType="TextBlock"><Setter Property="FontSize" Value="11.5"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Foreground" Value="#6B7280"/><Setter Property="Typography.CapitalSpacing" Value="True"/></Style>
    <Style x:Key="Val" TargetType="TextBlock"><Setter Property="FontFamily" Value="{DynamicResource Display}"/><Setter Property="FontSize" Value="25"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,5,0,0"/><Setter Property="Typography.NumeralAlignment" Value="Tabular"/></Style>
    <Style x:Key="H2" TargetType="TextBlock"><Setter Property="FontSize" Value="16.5"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
    <Style x:Key="Sub" TargetType="TextBlock"><Setter Property="FontSize" Value="13.5"/><Setter Property="Foreground" Value="#4B5563"/><Setter Property="Margin" Value="0,4,0,0"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="LineHeight" Value="20"/></Style>
    <Style x:Key="Th" TargetType="TextBlock"><Setter Property="FontSize" Value="11"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Foreground" Value="#6B7280"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="Typography.CapitalSpacing" Value="True"/></Style>
    <Style x:Key="Td" TargetType="TextBlock"><Setter Property="FontSize" Value="13.5"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="Typography.NumeralAlignment" Value="Tabular"/></Style>
    <Style x:Key="Table" TargetType="Border"><Setter Property="Background" Value="#66FFFFFF"/><Setter Property="BorderBrush" Value="#99FFFFFF"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="14"/><Setter Property="Padding" Value="0,2,0,6"/></Style>
    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="Background" Value="#E8E9EC"/><Setter Property="CornerRadius" Value="10"/><Setter Property="Padding" Value="12,4"/><Setter Property="HorizontalAlignment" Value="Left"/><Setter Property="VerticalAlignment" Value="Center"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Status}" Value="Scanning"><Setter Property="Background" Value="#DCE7FD"/></DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="Cleaning"><Setter Property="Background" Value="#FCEFD2"/></DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="Cleaned"><Setter Property="Background" Value="#DCF5E3"/></DataTrigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="PillText" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/><Setter Property="FontWeight" Value="Medium"/><Setter Property="Foreground" Value="#374151"/>
      <Style.Triggers>
        <DataTrigger Binding="{Binding Status}" Value="Scanning"><Setter Property="Foreground" Value="#1D4ED8"/></DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="Cleaning"><Setter Property="Foreground" Value="#B45309"/></DataTrigger>
        <DataTrigger Binding="{Binding Status}" Value="Cleaned"><Setter Property="Foreground" Value="#15803D"/></DataTrigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#F4F5F8" Offset="0"/><GradientStop Color="#E4E7EC" Offset="0.55"/><GradientStop Color="#EDEFF3" Offset="1"/></LinearGradientBrush>
    </Grid.Background>
    <Ellipse Width="760" Height="560" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-260,-200,0,0" Fill="{StaticResource Blob}" IsHitTestVisible="False"/>
    <Ellipse Width="680" Height="520" HorizontalAlignment="Center" VerticalAlignment="Center" Margin="260,-80,0,0" Fill="{StaticResource BlobGrey}" IsHitTestVisible="False"/>
    <Ellipse Width="900" Height="640" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,-300,-240" Fill="{StaticResource Blob}" IsHitTestVisible="False"/>
    <Ellipse Width="520" Height="420" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="-180,0,0,-120" Fill="{StaticResource BlobGrey}" IsHitTestVisible="False"/>

    <Grid Margin="24">
      <Grid.ColumnDefinitions><ColumnDefinition Width="236"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <ContentControl Style="{StaticResource Glass}" Padding="14,26,14,14">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="14,0,0,0">
            <Image Name="Logo" Width="76" Height="76" Margin="-8,-6,0,0" HorizontalAlignment="Left" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed"/>
            <TextBlock Name="LogoGlyph" Text="&#xE81E;" FontFamily="{StaticResource Icons}" FontSize="32"/>
            <TextBlock Text="AI Cache Cleaner" FontFamily="{DynamicResource Display}" FontSize="19" FontWeight="Bold" TextWrapping="NoWrap" Margin="0,10,0,0"/>
            <TextBlock Text="Regenerable caches, reclaimed." FontSize="12" Foreground="#6B7280" Margin="0,3,0,0"/>
          </StackPanel>
          <Button Name="SchedCard" DockPanel.Dock="Bottom" Cursor="Hand" ToolTip="Weekly auto-clean settings">
            <Button.Template><ControlTemplate TargetType="Button">
              <Border x:Name="b" Background="#B3FFFFFF" BorderBrush="#CCFFFFFF" BorderThickness="1" CornerRadius="16" Padding="14,13">
                <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Direction="270" Opacity="0.08"/></Border.Effect>
                <ContentPresenter/>
              </Border>
              <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#E6FFFFFF"/></Trigger></ControlTemplate.Triggers>
            </ControlTemplate></Button.Template>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Ellipse Name="CardDot" Width="12" Height="12" Fill="#9CA3AF" VerticalAlignment="Top" Margin="0,3,10,0"/>
              <StackPanel Grid.Column="1">
                <TextBlock Name="CardTitle" Text="Auto-clean off" FontSize="12.5" FontWeight="SemiBold"/>
                <TextBlock Name="CardSub" Text="Turn on in Settings" FontSize="12" Foreground="#4B5563" Margin="0,3,0,0"/>
              </StackPanel>
              <TextBlock Grid.Column="2" Text="&#xE76C;" FontFamily="{StaticResource Icons}" FontSize="10" Foreground="#6B7280" VerticalAlignment="Center"/>
            </Grid>
          </Button>
          <StackPanel Margin="0,36,0,0">
            <RadioButton Name="NavHome" Style="{StaticResource Nav}" Tag="&#xE80F;" Content="Home" IsChecked="True"/>
            <RadioButton Name="NavHistory" Style="{StaticResource Nav}" Tag="&#xE81C;" Content="Scan History"/>
            <RadioButton Name="NavSettings" Style="{StaticResource Nav}" Tag="&#xE713;" Content="Settings"/>
            <RadioButton Name="NavAbout" Style="{StaticResource Nav}" Tag="&#xE946;" Content="About"/>
          </StackPanel>
        </DockPanel>
      </ContentControl>

      <ContentControl Grid.Column="1" Margin="22,0,0,0" Style="{StaticResource Glass}">
        <ScrollViewer Name="Scroll" VerticalScrollBarVisibility="Auto" Focusable="False" Margin="0,14,6,14" Padding="26,12,22,6">
          <StackPanel>
            <Grid Margin="0,0,0,26">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Name="Eyebrow" Text="KEEP YOUR SYSTEM FAST" FontSize="12" FontWeight="SemiBold" Foreground="#6B7280" Typography.CapitalSpacing="True"/>
                <TextBlock Name="PageTitle" Text="AI Cache Cleaner" FontFamily="{DynamicResource Display}" FontSize="42" FontWeight="Bold" Margin="0,6,0,0"/>
                <TextBlock Name="Subtitle" FontSize="17" Foreground="#4B5563" TextWrapping="Wrap" MaxWidth="540" LineHeight="25" HorizontalAlignment="Left" Margin="0,8,0,0"/>
              </StackPanel>
              <StackPanel Name="HeaderButtons" Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Top">
                <Button Name="BtnLog" Style="{StaticResource Btn}" Tag="&#xE8A5;" Content="Open log"/>
                <Button Name="BtnScan" Style="{StaticResource Btn}" Tag="&#xE72C;" Content="Scan again"/>
                <Button Name="BtnClean" Style="{StaticResource Primary}" Tag="&#xEA99;" Content="Clean now"/>
              </StackPanel>
            </Grid>

            <StackPanel Name="PageHome">
              <ContentControl Style="{StaticResource Card}">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <ContentControl Style="{StaticResource Tile}" Content="&#xEDA2;" Width="64" Height="64" FontSize="26"/>
                  <StackPanel Grid.Column="1" Margin="24,0,6,0" VerticalAlignment="Center">
                    <TextBlock Name="DiskLabel" Text="Disk" Style="{StaticResource H2}" FontSize="20"/>
                    <TextBlock Name="DiskText" Style="{StaticResource Sub}" FontSize="15"/>
                    <Grid Margin="0,12,0,0">
                      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                      <ProgressBar Name="Disk"/>
                      <TextBlock Name="DiskPct" Grid.Column="1" Margin="28,0,0,0" FontSize="15" Foreground="#4B5563" VerticalAlignment="Center"/>
                    </Grid>
                  </StackPanel>
                </Grid>
              </ContentControl>

              <UniformGrid Columns="4" Margin="-9,0">
                <ContentControl Style="{StaticResource Card}" Margin="9,0,9,18" Padding="18,18">
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE74D;" Width="48" Height="48" FontSize="20"/>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center"><TextBlock Text="FREED THIS RUN" Style="{StaticResource Cap}"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock Name="StatFreed" Text="0.00 GB" Style="{StaticResource Val}"/></Viewbox></StackPanel>
                  </Grid>
                </ContentControl>
                <ContentControl Style="{StaticResource Card}" Margin="9,0,9,18" Padding="18,18">
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE7B8;" Width="48" Height="48" FontSize="20"/>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center"><TextBlock Text="CAN BE FREED" Style="{StaticResource Cap}"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock Name="StatFound" Text="-" Style="{StaticResource Val}"/></Viewbox></StackPanel>
                  </Grid>
                </ContentControl>
                <ContentControl Style="{StaticResource Card}" Margin="9,0,9,18" Padding="18,18">
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE8A5;" Width="48" Height="48" FontSize="20"/>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center"><TextBlock Text="ITEMS CLEARED" Style="{StaticResource Cap}"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock Name="StatCleared" Text="0" Style="{StaticResource Val}"/></Viewbox></StackPanel>
                  </Grid>
                </ContentControl>
                <ContentControl Style="{StaticResource Card}" Margin="9,0,9,18" Padding="18,18">
                  <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE823;" Width="48" Height="48" FontSize="20"/>
                    <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center"><TextBlock Text="FREED ALL-TIME" Style="{StaticResource Cap}"/><Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock Name="StatAll" Text="0.00 GB" Style="{StaticResource Val}"/></Viewbox></StackPanel>
                  </Grid>
                </ContentControl>
              </UniformGrid>

              <ContentControl Style="{StaticResource Card}" Padding="22,18">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid Width="48" Height="48" Margin="4,0,0,0">
                    <Ellipse><Ellipse.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="0,1"><GradientStop Color="#717782" Offset="0"/><GradientStop Color="#4B5160" Offset="1"/></LinearGradientBrush></Ellipse.Fill></Ellipse>
                    <TextBlock Name="BannerIcon" Text="&#xE72C;" FontFamily="{StaticResource Icons}" FontSize="20" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                      <TextBlock.RenderTransform><RotateTransform/></TextBlock.RenderTransform>
                    </TextBlock>
                  </Grid>
                  <StackPanel Grid.Column="1" Margin="22,0,24,0" VerticalAlignment="Center">
                    <TextBlock Name="BannerTitle" Text="Starting..." Style="{StaticResource H2}"/>
                    <TextBlock Name="BannerSub" Style="{StaticResource Sub}"/>
                    <ProgressBar Name="Bar" Height="4" Margin="0,10,0,0"/>
                  </StackPanel>
                  <Button Name="BtnClean2" Grid.Column="2" Style="{StaticResource Primary}" Tag="&#xEA99;" Content="Clean now" Padding="28,14" FontSize="15.5" VerticalAlignment="Center"/>
                </Grid>
              </ContentControl>

              <ContentControl Style="{StaticResource Card}" Padding="18,18,18,14">
                <StackPanel>
                  <Grid Margin="0,0,0,16">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE81E;"/>
                    <StackPanel Grid.Column="1" Margin="20,0,12,0" VerticalAlignment="Center">
                      <TextBlock Text="Detected Cache &amp; Temporary Files" Style="{StaticResource H2}"/>
                      <TextBlock Text="Regenerable caches: tools rebuild anything they need on their own." Style="{StaticResource Sub}"/>
                    </StackPanel>
                    <Border Grid.Column="2" Background="#CCFFFFFF" BorderBrush="#E5E7EB" BorderThickness="1" CornerRadius="12" Padding="18,10" VerticalAlignment="Center">
                      <TextBlock FontSize="15"><Run Text="Total reclaimable: "/><Run Name="TotalRun" Text="-" FontWeight="SemiBold"/></TextBlock>
                    </Border>
                  </Grid>
                  <Border Style="{StaticResource Table}">
                    <StackPanel>
                      <Grid Height="42">
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="56"/><ColumnDefinition Width="50"/><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/>
                          <ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition Width="100"/><ColumnDefinition Width="48"/>
                        </Grid.ColumnDefinitions>
                        <CheckBox Name="SelAll" HorizontalAlignment="Center" ToolTip="Tick or untick every cache"/>
                        <TextBlock Grid.Column="1" Grid.ColumnSpan="2" Text="TARGET" Style="{StaticResource Th}"/>
                        <TextBlock Grid.Column="3" Text="STATUS" Style="{StaticResource Th}"/>
                        <TextBlock Grid.Column="4" Text="ITEMS" Style="{StaticResource Th}"/>
                        <TextBlock Grid.Column="5" Text="SIZE" Style="{StaticResource Th}"/>
                        <TextBlock Grid.Column="6" Text="FREED" Style="{StaticResource Th}"/>
                      </Grid>
                      <ItemsControl Name="Rows">
                        <ItemsControl.ItemTemplate><DataTemplate>
                          <Border x:Name="row" Background="Transparent" CornerRadius="10" Margin="6,0">
                            <StackPanel>
                              <Grid Height="42">
                                <Grid.ColumnDefinitions>
                                  <ColumnDefinition Width="50"/><ColumnDefinition Width="50"/><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/>
                                  <ColumnDefinition Width="80"/><ColumnDefinition Width="100"/><ColumnDefinition Width="100"/><ColumnDefinition Width="42"/>
                                </Grid.ColumnDefinitions>
                                <CheckBox IsChecked="{Binding Selected, Mode=TwoWay}" HorizontalAlignment="Center"/>
                                <Border Grid.Column="1" Width="30" Height="30" CornerRadius="8" Background="{Binding Color}" HorizontalAlignment="Left">
                                  <TextBlock Text="{Binding Badge}" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center">
                                    <TextBlock.Style><Style TargetType="TextBlock">
                                      <Setter Property="FontWeight" Value="Bold"/><Setter Property="FontSize" Value="11.5"/>
                                      <Style.Triggers><DataTrigger Binding="{Binding Key}" Value="temp">
                                        <Setter Property="FontFamily" Value="{StaticResource Icons}"/><Setter Property="FontWeight" Value="Normal"/><Setter Property="FontSize" Value="15"/>
                                      </DataTrigger></Style.Triggers>
                                    </Style></TextBlock.Style>
                                  </TextBlock>
                                </Border>
                                <TextBlock Grid.Column="2" Text="{Binding Name}" Style="{StaticResource Td}" Margin="0,0,12,0"/>
                                <Border Grid.Column="3" Style="{StaticResource Pill}"><TextBlock Text="{Binding Status}" Style="{StaticResource PillText}"/></Border>
                                <TextBlock Grid.Column="4" Text="{Binding Items}" Style="{StaticResource Td}"/>
                                <TextBlock Grid.Column="5" Text="{Binding Size}" Style="{StaticResource Td}"/>
                                <TextBlock Grid.Column="6" Text="{Binding Freed}" Style="{StaticResource Td}" Foreground="#15803D"/>
                                <ToggleButton Grid.Column="7" Style="{StaticResource Chevron}" IsChecked="{Binding Expanded, Mode=TwoWay}" ToolTip="Show items"/>
                              </Grid>
                              <TextBlock Text="{Binding Details}" Visibility="{Binding Expanded, Converter={StaticResource Vis}}" FontFamily="Consolas" FontSize="12"
                                         Foreground="#4B5563" Margin="100,2,24,14" TextTrimming="CharacterEllipsis"/>
                            </StackPanel>
                          </Border>
                          <DataTemplate.Triggers>
                            <Trigger SourceName="row" Property="IsMouseOver" Value="True"><Setter TargetName="row" Property="Background" Value="#80FFFFFF"/></Trigger>
                          </DataTemplate.Triggers>
                        </DataTemplate></ItemsControl.ItemTemplate>
                      </ItemsControl>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </ContentControl>

              <ContentControl Style="{StaticResource Card}">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <ContentControl Style="{StaticResource Tile}" Content="&#xE823;"/>
                  <StackPanel Grid.Column="1" Margin="22,0,16,0" VerticalAlignment="Center">
                    <TextBlock Text="Cleared Items / Activity" Style="{StaticResource H2}"/>
                    <TextBlock Name="Activity" Text="Items will be listed here as they are cleared." Style="{StaticResource Sub}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <Button Name="BtnHistory" Grid.Column="2" Style="{StaticResource Link}" Content="View full history" VerticalAlignment="Center" Margin="0,0,10,0"/>
                </Grid>
              </ContentControl>
            </StackPanel>

            <StackPanel Name="PageHistory" Visibility="Collapsed">
              <ContentControl Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="This session" Style="{StaticResource H2}"/>
                  <TextBlock Text="Everything cleared since the app opened, including items skipped because they were in use." Style="{StaticResource Sub}"/>
                  <Border Style="{StaticResource Table}" Margin="0,14,0,0" Padding="16,12">
                    <TextBlock Name="SessionList" FontFamily="Consolas" FontSize="12" Foreground="#374151" TextTrimming="CharacterEllipsis"/>
                  </Border>
                </StackPanel>
              </ContentControl>
              <ContentControl Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Past runs" Style="{StaticResource H2}"/>
                  <TextBlock Text="Every cleanup in clean.log, newest first." Style="{StaticResource Sub}"/>
                  <Border Style="{StaticResource Table}" Margin="0,14,0,0">
                    <StackPanel>
                      <Grid Height="40" Margin="20,0">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/><ColumnDefinition Width="140"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
                        <TextBlock Text="WHEN" Style="{StaticResource Th}"/><TextBlock Grid.Column="1" Text="TYPE" Style="{StaticResource Th}"/>
                        <TextBlock Grid.Column="2" Text="FREED" Style="{StaticResource Th}"/><TextBlock Grid.Column="3" Text="ITEMS" Style="{StaticResource Th}"/>
                      </Grid>
                      <ItemsControl Name="Runs">
                        <ItemsControl.ItemTemplate><DataTemplate>
                          <Grid Height="38" Margin="20,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="140"/><ColumnDefinition Width="140"/><ColumnDefinition Width="100"/></Grid.ColumnDefinitions>
                            <TextBlock Text="{Binding When}" Style="{StaticResource Td}"/><TextBlock Grid.Column="1" Text="{Binding Mode}" Style="{StaticResource Td}"/>
                            <TextBlock Grid.Column="2" Text="{Binding Freed}" Style="{StaticResource Td}"/><TextBlock Grid.Column="3" Text="{Binding Items}" Style="{StaticResource Td}"/>
                          </Grid>
                        </DataTemplate></ItemsControl.ItemTemplate>
                      </ItemsControl>
                      <TextBlock Name="RunsEmpty" Text="No cleanups yet." Style="{StaticResource Sub}" Margin="20,4,20,10"/>
                    </StackPanel>
                  </Border>
                </StackPanel>
              </ContentControl>
            </StackPanel>

            <StackPanel Name="PageSettings" Visibility="Collapsed">
              <ContentControl Style="{StaticResource Card}">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE823;"/>
                    <StackPanel Grid.Column="1" Margin="20,0,16,0" VerticalAlignment="Center">
                      <TextBlock Text="Weekly auto-clean" Style="{StaticResource H2}"/>
                      <TextBlock Text="Cleans the ticked caches once a week, as you and without admin rights. Off unless you turn it on." Style="{StaticResource Sub}"/>
                    </StackPanel>
                    <CheckBox Name="SchedSwitch" Grid.Column="2" Style="{StaticResource Switch}" Margin="0,0,6,0"/>
                  </Grid>
                  <TextBlock Name="SchedHint" Text="Install the app first (double-click install.cmd) to turn on auto-clean." Foreground="#B45309" Margin="74,12,0,0" Visibility="Collapsed"/>
                  <Grid Margin="74,20,0,4">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="48"/><RowDefinition Height="48"/><RowDefinition Height="34"/><RowDefinition Height="34"/></Grid.RowDefinitions>
                    <TextBlock Text="Day" VerticalAlignment="Center" Foreground="#4B5563"/><ComboBox Name="SchedDay" Grid.Column="1"/>
                    <TextBlock Grid.Row="1" Text="Time" VerticalAlignment="Center" Foreground="#4B5563"/><ComboBox Name="SchedHour" Grid.Row="1" Grid.Column="1"/>
                    <TextBlock Grid.Row="2" Text="Next run" VerticalAlignment="Center" Foreground="#4B5563"/><TextBlock Name="SchedNext" Grid.Row="2" Grid.Column="1" VerticalAlignment="Center"/>
                    <TextBlock Grid.Row="3" Text="Last auto-clean" VerticalAlignment="Center" Foreground="#4B5563"/><TextBlock Name="SchedLast" Grid.Row="3" Grid.Column="1" VerticalAlignment="Center"/>
                  </Grid>
                </StackPanel>
              </ContentControl>
              <ContentControl Style="{StaticResource Card}">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <ContentControl Style="{StaticResource Tile}" Content="&#xE713;"/>
                    <StackPanel Grid.Column="1" Margin="20,0,16,0" VerticalAlignment="Center">
                      <TextBlock Text="What gets cleaned" Style="{StaticResource H2}"/>
                      <TextBlock Text="Untick a cache on Home to leave it alone. Clean now and the weekly auto-clean both follow your ticks." Style="{StaticResource Sub}"/>
                    </StackPanel>
                  </Grid>
                  <Grid Margin="74,20,0,4">
                    <Grid.ColumnDefinitions><ColumnDefinition Width="160"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <TextBlock Text="Temp files older than" VerticalAlignment="Center" Foreground="#4B5563"/>
                    <ComboBox Name="TempDays" Grid.Column="1"/>
                    <TextBlock Grid.Column="2" Text="Applies from the next scan." VerticalAlignment="Center" Foreground="#6B7280" Margin="16,0,0,0"/>
                  </Grid>
                </StackPanel>
              </ContentControl>
            </StackPanel>

            <StackPanel Name="PageAbout" Visibility="Collapsed">
              <ContentControl Style="{StaticResource Card}">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <Grid>
                    <ContentControl Name="AboutTile" Style="{StaticResource Tile}" Content="&#xE81E;" Width="64" Height="64" FontSize="28"/>
                    <Image Name="AboutLogo" Width="76" Height="76" RenderOptions.BitmapScalingMode="HighQuality" Visibility="Collapsed"/>
                  </Grid>
                  <StackPanel Grid.Column="1" Margin="22,0,16,0" VerticalAlignment="Center">
                    <TextBlock Text="AI Cache Cleaner" Style="{StaticResource H2}" FontSize="20"/>
                    <TextBlock Name="AboutVersion" Style="{StaticResource Sub}"/>
                    <TextBlock Text="Frees disk space taken by regenerable AI and developer caches: uv, npm, pnpm, pip, conda, Temp and Playwright." Style="{StaticResource Sub}"/>
                  </StackPanel>
                  <Button Name="BtnFolder" Grid.Column="2" Style="{StaticResource Btn}" Tag="&#xE8B7;" Content="Open install folder" VerticalAlignment="Center"/>
                </Grid>
              </ContentControl>
              <ContentControl Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="Safety &amp; security" Style="{StaticResource H2}"/>
                  <ItemsControl Name="Safety" Margin="0,14,0,0">
                    <ItemsControl.ItemTemplate><DataTemplate>
                      <Grid Margin="0,0,0,12">
                        <Grid.ColumnDefinitions><ColumnDefinition Width="34"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                        <Border Width="22" Height="22" CornerRadius="11" Background="#DCF5E3" VerticalAlignment="Top">
                          <TextBlock Text="&#xE73E;" FontFamily="{StaticResource Icons}" FontSize="11" Foreground="#15803D" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Grid.Column="1" Text="{Binding}" TextWrapping="Wrap" FontSize="14.5" Margin="0,1,0,0"/>
                      </Grid>
                    </DataTemplate></ItemsControl.ItemTemplate>
                  </ItemsControl>
                </StackPanel>
              </ContentControl>
            </StackPanel>
          </StackPanel>
        </ScrollViewer>
      </ContentControl>
    </Grid>
  </Grid>
</Window>
'@
  $w = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
  $ui = @{}; $xaml.SelectNodes('//*[@Name]') | ForEach-Object { $ui[$_.Name] = $w.FindName($_.Name) }
  $wa = [Windows.SystemParameters]::WorkArea
  $w.Height = [math]::Min(1000, $wa.Height - 40); $w.Width = [math]::Min(1320, $wa.Width - 40)
  # Inter (Google Fonts, OFL) ships in fonts\ and loads from disk: nothing is fetched at runtime. Without it, Segoe UI.
  $fonts = Join-Path $PSScriptRoot 'fonts\'
  # ::new, not New-Object: a ResourceDictionary would store New-Object's PSObject wrapper, which WPF rejects as a font.
  try {
    if (Test-Path -LiteralPath (Join-Path $fonts 'Inter-Regular.ttf')) {
      $inter = [Windows.Media.FontFamily]::new([Uri]::new($fonts), './#Inter, Segoe UI')
      $w.Resources['Body'] = $inter; $w.Resources['Display'] = $inter
    }
  } catch {}
  # The logo ships next to the script; without it the window falls back to the Disk Cleanup icon and a glyph.
  try {
    $fs = [IO.File]::OpenRead((Join-Path $PSScriptRoot 'logo.png'))
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit(); $img.StreamSource = $fs; $img.CacheOption = 'OnLoad'; $img.EndInit(); $fs.Close()
    $w.Icon = $ui.Logo.Source = $ui.AboutLogo.Source = $img
    $ui.Logo.Visibility = $ui.AboutLogo.Visibility = 'Visible'; $ui.LogoGlyph.Visibility = $ui.AboutTile.Visibility = 'Collapsed'
  } catch {
    try { $w.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon([Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\cleanmgr.exe").Handle,
        [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) } catch {}
  }

  $rows = New-Object 'Collections.ObjectModel.ObservableCollection[CacheRow]'
  $ui.Rows.ItemsSource = $rows
  $session = New-Object 'Collections.Generic.List[string]'
  $q = New-Object 'Collections.Concurrent.ConcurrentQueue[object]'
  $st = @{ Ps = $null; Handle = $null; Clean = $false; Busy = $false; Cleared = 0; Error = $null; Loading = $false }
  # Letter badges in each tool's brand colour (letters only, no logos); Temp gets a document glyph.
  $badges = @{ uv = 'uv', '#6E40F0'; npm = 'npm', '#CB3837'; pnpm = 'pn', '#F69220'; pip = 'py', '#3776AB'; conda = 'C', '#43B02A'
    temp = [string][char]0xE8A5, '#9CA3AF'; playwright = 'PW', '#2EAD33' }
  $dot = [char]0xB7
  $pages = @{
    NavHome     = 'PageHome', 'KEEP YOUR SYSTEM FAST', 'AI Cache Cleaner', 'Find and remove regenerable AI and developer caches to free up space. Tools rebuild anything they need on their own.'
    NavHistory  = 'PageHistory', 'SCAN HISTORY', 'Scan History', 'Everything cleared this session, and every cleanup before it.'
    NavSettings = 'PageSettings', 'SETTINGS', 'Settings', 'Choose what gets cleaned, and whether it happens on its own each week.'
    NavAbout    = 'PageAbout', 'ABOUT', 'About', 'What AI Cache Cleaner does, and what it never does.'
  }
  $ui.AboutVersion.Text = "Version $Version"
  $ui.Safety.ItemsSource = @(
    'Works offline: no telemetry, no update checks, nothing is sent anywhere.'
    'Runs as you, without admin rights.'
    'Deletes only caches that tools rebuild on their own. Models, venvs, conda envs and your files are never touched.'
    'Skips anything in use: open files, running programs, and tools in the middle of an install.'
    'Never follows links: a junction or symlink is removed as a link, and its target is left alone.'
    'Keeps every Playwright browser build that an installed project still needs.'
    'Weekly auto-clean is optional and stays off until you turn it on.'
    'One plain PowerShell script you can read before you run it.')
  $ui.SchedDay.ItemsSource = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
  $ui.SchedHour.ItemsSource = @(0..23 | ForEach-Object { '{0:00}:00' -f $_ })
  $ui.SchedDay.SelectedItem = 'Sunday'; $ui.SchedHour.SelectedIndex = 13

  $spin = New-Object Windows.Media.Animation.DoubleAnimation
  $spin.From = 0; $spin.To = 360; $spin.Duration = New-Object Windows.Duration ([TimeSpan]::FromSeconds(1.2))
  $spin.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
  $banner = { param([int]$glyph, $title, $sub)
    $ui.BannerIcon.Text = [string][char]$glyph
    $ui.BannerIcon.RenderTransform.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $(if ($glyph -eq 0xE72C) { $spin } else { $null }))
    $ui.BannerTitle.Text = $title; $ui.BannerSub.Text = $sub
  }
  $selectedBytes = { $b = 0.0; foreach ($r in $rows) { if ($r.Selected) { $b += [math]::Max(0.0, $r.Bytes - $r.FreedBytes) } }; $b }   # 0.0: an int 0 picks Max(int, int), which throws past 2 GB

  $updateTotals = {
    $freed = 0.0; foreach ($r in $rows) { $freed += $r.FreedBytes }
    $sel = & $selectedBytes
    $ui.StatFreed.Text = '{0:N2} GB' -f ($freed / 1GB)
    $ui.StatFound.Text = $ui.TotalRun.Text = '{0:N2} GB' -f ($sel / 1GB)
    $ui.StatCleared.Text = $st.Cleared
    $n = @($rows | Where-Object Selected).Count
    $ui.SelAll.IsChecked = if ($rows.Count -and $n -eq $rows.Count) { $true } elseif ($n) { $null } else { $false }
    $ui.BtnClean.IsEnabled = $ui.BtnClean2.IsEnabled = (-not $st.Busy -and $n -gt 0)
    $ui.BtnScan.IsEnabled = -not $st.Busy
  }

  $saveSkip = {
    $s = Get-Settings $SettingsPath
    $s.skip = @($rows | Where-Object { -not $_.Selected } | ForEach-Object Key)
    try { Save-Settings $SettingsPath $s } catch {}
  }
  $onRowChanged = { param($sender, $e) if ($e.PropertyName -eq 'Selected' -and -not $st.Loading) { & $saveSkip; & $updateTotals } }

  $refresh = {
    $d = New-Object IO.DriveInfo ($env:LOCALAPPDATA.Substring(0, 1))
    $used = $d.TotalSize - $d.TotalFreeSpace
    $ui.DiskLabel.Text = 'Disk ' + $d.Name.TrimEnd('\')
    $ui.DiskText.Text = '{0:N1} GB free of {1:N0} GB' -f ($d.TotalFreeSpace / 1GB), ($d.TotalSize / 1GB)
    $ui.Disk.Value = 100 * $used / $d.TotalSize
    $ui.DiskPct.Text = '{0:N0}% used' -f (100 * $used / $d.TotalSize)
    $runs = @(Read-Log $LogPath)
    $ui.StatAll.Text = '{0:N2} GB' -f [double]($runs | Measure-Object FreedGB -Sum).Sum
    $ui.Runs.ItemsSource = @($runs | Sort-Object Date -Descending | ForEach-Object {
        [pscustomobject]@{ When = '{0:ddd d MMM yyyy, HH:mm}' -f $_.Date; Mode = $(if ($_.Mode -eq 'auto') { 'Auto' } elseif ($_.Mode) { 'Manual' } else { '-' })
          Freed = '{0:N2} GB' -f $_.FreedGB; Items = $(if ($_.Items) { $_.Items } else { '-' }) } })
    $ui.RunsEmpty.Visibility = if ($runs.Count) { 'Collapsed' } else { 'Visible' }
    $ui.SessionList.Text = if ($session.Count) { $session -join "`n" } else { 'Nothing cleared yet this session.' }
    $ui.BtnFolder.IsEnabled = Test-Path -LiteralPath $AppDir
  }

  $loadSched = {
    $st.Loading = $true
    $exeOk = Test-Path -LiteralPath (Join-Path $AppDir $ExeName)
    $s = Get-Schedule
    $ui.SchedSwitch.IsEnabled = $exeOk
    $ui.SchedHint.Visibility = if ($exeOk) { 'Collapsed' } else { 'Visible' }
    $ui.SchedSwitch.IsChecked = [bool]$s
    if ($s) { $ui.SchedDay.SelectedItem = $s.Day; $ui.SchedHour.SelectedIndex = $s.Hour }
    $ui.SchedNext.Text = if ($s -and $s.Next) { '{0:dddd d MMMM, HH:mm}' -f $s.Next } else { '-' }
    $last = Read-Log $LogPath | Where-Object Mode -eq 'auto' | Select-Object -Last 1
    $ui.SchedLast.Text = if ($last) { '{0:ddd d MMM, HH:mm}: freed {1:N2} GB, {2} items' -f $last.Date, $last.FreedGB, $last.Items } else { 'No auto-clean has run yet.' }
    $ui.CardTitle.Text = if ($s) { 'Auto-clean enabled' } else { 'Auto-clean off' }
    $ui.CardSub.Text = if ($s) { 'Weekly {0} {1} {2:00}:00' -f $dot, $s.Day.Substring(0, 3), $s.Hour } else { 'Turn on in Settings' }
    $ui.CardDot.Fill = [Windows.Media.BrushConverter]::new().ConvertFromString($(if ($s) { '#22C55E' } else { '#9CA3AF' }))
    $s = Get-Settings $SettingsPath
    $ui.TempDays.ItemsSource = @(@(1, 2, 3, 7, 14, 30, 90) + $s.tempDays | Sort-Object -Unique | ForEach-Object { if ($_ -eq 1) { '1 day' } else { "$_ days" } })
    $ui.TempDays.SelectedIndex = [array]::IndexOf(@($ui.TempDays.ItemsSource), $(if ($s.tempDays -eq 1) { '1 day' } else { "$($s.tempDays) days" }))
    $st.Loading = $false
  }
  $applySched = {
    if ($st.Loading) { return }
    try { if ($ui.SchedSwitch.IsChecked) { Set-Schedule $ui.SchedDay.SelectedItem $ui.SchedHour.SelectedIndex } else { Remove-Schedule } }
    catch { [void][Windows.MessageBox]::Show($w, "Couldn't change the weekly auto-clean:`n`n$_", $AppName) }
    & $loadSched
  }

  $show = { param($nav)
    foreach ($k in $pages.Keys) { $ui[$pages[$k][0]].Visibility = if ($k -eq $nav) { 'Visible' } else { 'Collapsed' } }
    $ui.Eyebrow.Text = $pages[$nav][1]; $ui.PageTitle.Text = $pages[$nav][2]; $ui.Subtitle.Text = $pages[$nav][3]
    $ui.HeaderButtons.Visibility = if ($nav -eq 'NavHome') { 'Visible' } else { 'Collapsed' }
    if ($nav -eq 'NavHistory') { & $refresh }
    if ($nav -eq 'NavSettings') { & $loadSched }
    $ui.Scroll.ScrollToTop()
  }

  $start = { param([bool]$clean)
    if ($st.Busy) { return }
    $s = Get-Settings $SettingsPath
    $st.Busy = $true; $st.Clean = $clean; $st.Cleared = 0; $st.Error = $null
    foreach ($r in $rows) { $r.Status = 'Waiting'; $r.Freed = ''; $r.FreedBytes = 0 }
    $ui.Bar.Value = 0; $ui.Bar.Visibility = 'Visible'
    if ($clean) { & $banner 0xEA99 'Cleaning...' 'Removing the ticked caches. Anything in use is skipped.' }
    else { & $banner 0xE72C 'Scanning...' 'Measuring caches. Nothing is deleted.' }
    & $updateTotals
    $iss = [initialsessionstate]::CreateDefault()
    foreach ($f in Get-ChildItem function: | Where-Object { $_.ScriptBlock.File -eq $PSCommandPath }) {
      $iss.Commands.Add((New-Object Management.Automation.Runspaces.SessionStateFunctionEntry $f.Name, $f.Definition))
    }
    # The work runs on a background runspace; it only talks to the window through $q, drained by the timer below.
    $st.Ps = [powershell]::Create($iss)
    [void]$st.Ps.AddScript({ param($clean, $days, $skip, $log, $q)
        try { Invoke-Cleaner $clean $days $skip $log 'manual' { $q.Enqueue($args[0]) } | Out-Null } catch { $q.Enqueue(@{ Error = "$_" }) }
        $q.Enqueue(@{ End = $true })
      }).AddArgument($clean).AddArgument($s.tempDays).AddArgument([string[]]$s.skip).AddArgument($LogPath).AddArgument($q)
    $st.Handle = $st.Ps.BeginInvoke()
  }

  $finish = {
    try { [void]$st.Ps.EndInvoke($st.Handle) } catch {}
    $st.Ps.Dispose(); $st.Ps = $null; $st.Busy = $false
    $ui.Bar.Visibility = 'Collapsed'
    $freed = 0.0; foreach ($r in $rows) { $freed += $r.FreedBytes }
    $sel = & $selectedBytes
    if ($st.Error) { & $banner 0xE7BA 'Something went wrong' $st.Error }
    elseif ($st.Clean) { & $banner 0xE73E ('Done: freed {0:N2} GB.' -f ($freed / 1GB)) ('{0} items cleared. Anything in use was skipped and is tried again next time.' -f $st.Cleared) }
    elseif ($sel -gt 0) { & $banner 0xE73E ('Scan complete: {0:N2} GB can be freed.' -f ($sel / 1GB)) 'Nothing was deleted. Click Clean now to free it.' }
    else { & $banner 0xE73E 'Scan complete: nothing to clean.' 'Nothing was deleted. Your caches are already tidy.' }
    & $refresh
  }

  $timer = New-Object Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(120)
  $timer.Add_Tick({
    $m = $null; $any = $false
    while ($q.TryDequeue([ref]$m)) {
      $any = $true
      if ($m.Targets) {
        if ($rows.Count -ne $m.Targets.Count) {
          $st.Loading = $true; $s = Get-Settings $SettingsPath; $rows.Clear()
          foreach ($t in $m.Targets) {
            $r = New-Object CacheRow
            $r.Key = $t.Key; $r.Badge = $badges[$t.Key][0]; $r.Color = $badges[$t.Key][1]; $r.Selected = $s.skip -notcontains $t.Key; $r.Status = 'Waiting'
            $r.add_PropertyChanged($onRowChanged); $rows.Add($r)
          }
          $st.Loading = $false
        }
        for ($k = 0; $k -lt $rows.Count; $k++) { $rows[$k].Name = $m.Targets[$k].Name }
      }
      if ($m.ContainsKey('P')) { $ui.Bar.Value = 100 * $m.P }
      if ($m.ContainsKey('I')) {
        $r = $rows[$m.I]
        if ($m.Status) { $r.Status = $m.Status; $ui.BannerSub.Text = '{0}: {1}' -f $m.Status, $r.Name }
        if ($m.Row) {
          $x = $m.Row
          $r.Status = $x.Status; $r.Items = [string]$x.Items; $r.Bytes = $x.Bytes; $r.Size = '{0:N2} GB' -f ($x.Bytes / 1GB)
          $r.FreedBytes = $x.FreedBytes; $r.Freed = if ($st.Clean) { '{0:N2} GB' -f ($x.FreedBytes / 1GB) } else { '' }
          $lines = @()
          if ($x.Note) { $lines += "Note: $($x.Note)" }
          if ($x.Command) { $lines += "Cleaned by running: $($x.Command)" }
          $lines += @($x.Details | Select-Object -First 100 | ForEach-Object { '{0,10}  {1}' -f (Format-Size $_.Bytes), $_.Path })
          if ($x.Details.Count -gt 100) { $lines += '... and {0} more' -f ($x.Details.Count - 100) }
          if (-not $x.Details.Count) { $lines += 'Nothing found.' }
          $r.Details = $lines -join "`n"
        }
      }
      if ($m.Log) {
        $session.Add($m.Log); $ui.Activity.Text = $m.Log
        if ($m.Log -match '^(removed|ran)') { $st.Cleared++ }
      }
      if ($m.Error) { $st.Error = $m.Error }
      if ($m.End) { & $finish }
    }
    if ($any) { & $updateTotals }
  })

  $confirmClean = {
    $msg = "Delete the ticked caches ({0:N2} GB)?`n`nAnything in use is skipped, and tools re-download what they need. Models, venvs and conda envs are never touched." -f ((& $selectedBytes) / 1GB)
    if ([Windows.MessageBox]::Show($w, $msg, $AppName, 'YesNo', 'Question') -eq 'Yes') { & $start $true }
  }
  $ui.BtnClean.Add_Click($confirmClean); $ui.BtnClean2.Add_Click($confirmClean)
  $ui.BtnScan.Add_Click({ & $start $false })
  $ui.BtnLog.Add_Click({
      if (Test-Path -LiteralPath $LogPath) { Start-Process -FilePath "$env:SystemRoot\System32\notepad.exe" -ArgumentList "`"$LogPath`"" }
      else { [void][Windows.MessageBox]::Show($w, 'No cleanups logged yet.', $AppName) } })
  $ui.BtnFolder.Add_Click({ Start-Process -FilePath "$env:SystemRoot\explorer.exe" -ArgumentList "`"$AppDir`"" })
  $ui.BtnHistory.Add_Click({ $ui.NavHistory.IsChecked = $true })
  $ui.SchedCard.Add_Click({ $ui.NavSettings.IsChecked = $true })
  $ui.SelAll.Add_Click({ $v = $ui.SelAll.IsChecked -eq $true; foreach ($r in $rows) { $r.Selected = $v } })
  foreach ($k in $pages.Keys) { $ui[$k].Add_Checked({ param($sender) & $show $sender.Name }) }
  $ui.SchedSwitch.Add_Checked($applySched); $ui.SchedSwitch.Add_Unchecked($applySched)   # not Click: accessibility tools toggle without clicking
  $ui.SchedDay.Add_SelectionChanged({ if ($ui.SchedSwitch.IsChecked) { & $applySched } })
  $ui.SchedHour.Add_SelectionChanged({ if ($ui.SchedSwitch.IsChecked) { & $applySched } })
  $ui.TempDays.Add_SelectionChanged({
      if ($st.Loading -or -not $ui.TempDays.SelectedItem) { return }
      $s = Get-Settings $SettingsPath; $s.tempDays = [int]($ui.TempDays.SelectedItem -replace '\D'); try { Save-Settings $SettingsPath $s } catch {} })
  $w.Add_Loaded({ & $show 'NavHome'; & $refresh; & $loadSched; $timer.Start(); & $start $false })   # scan right away so the window opens with real numbers
  $w.Add_Closed({ $timer.Stop(); if ($st.Ps) { [void]$st.Ps.BeginStop($null, $null) } })
  [void]$w.ShowDialog()
  return
}

$s = Get-Settings $SettingsPath
$days = if ($TempDays) { $TempDays } else { $s.tempDays }
$print = if ($Clean) { { if ($args[0].Log) { Write-Host $args[0].Log } } } else { {} }
$rows = @(Invoke-Cleaner $Clean $days $s.skip $LogPath 'manual' $print)
$rows | Format-Table Target, Status, Items, SizeGB, FreedGB -AutoSize | Out-String -Width 200
if ($Clean) { 'Freed {0:N2} GB' -f ($rows | Measure-Object FreedGB -Sum).Sum; return }
'Dry run: {0:N2} GB can be freed. Re-run with -Clean to free it.' -f ($rows | Where-Object { $s.skip -notcontains $_.Key } | Measure-Object SizeGB -Sum).Sum
if ($s.skip) { 'Unticked in the app, so -Clean leaves these alone: ' + ($s.skip -join ', ') }
"`nModels / envs / AI runtimes - review by hand, never auto-deleted:"
$watch = "$HOME\.cache\huggingface\hub\models--*", "$HOME\.lmstudio\models\*\*", "$HOME\.cache\lm-studio\models\*\*", "$HOME\.ollama\models",
  "$HOME\.cache\torch", "$HOME\.conda\envs\*", "$HOME\.venvs\*", "$env:LOCALAPPDATA\Programs\Python\Python3*\Lib\site-packages\torch",
  "$HOME\Documents\ComfyUI\models", "$env:APPDATA\Block\goose\data\models", "$env:ProgramData\Topaz Labs LLC\*\models"
Get-Item $watch -Force -ErrorAction SilentlyContinue |
  ForEach-Object { [pscustomobject]@{ SizeGB = [math]::Round((Get-Size $_.FullName) / 1GB, 2); LastWrite = '{0:yyyy-MM-dd}' -f $_.LastWriteTime; Path = $_.FullName } } |
  Where-Object SizeGB -ge 0.1 | Sort-Object SizeGB -Descending | Format-Table -AutoSize | Out-String -Width 250

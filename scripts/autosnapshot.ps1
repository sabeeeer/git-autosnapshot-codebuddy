#requires -Version 7.0
<#
.SYNOPSIS
    git-management skill - automatic git snapshot engine (rate-limited commit + optional file watcher).

.DESCRIPTION
    Mode 1 (default, used by CodeBuddy PostToolUse hook): run one rate-limited snapshot
        1. locate target repo (-Path, else $env:CODEBUDDY_PROJECT_DIR / $env:CLAUDE_PROJECT_DIR / cwd)
        2. if less than -IntervalSeconds elapsed since the last auto snapshot, exit quietly
        3. if "git status --porcelain" shows no change, exit quietly (never create an empty commit)
        4. otherwise: use a temporary index + commit-tree to snapshot all worktree changes
           without running git add/commit against the user's real index

    Mode 2 (-Watch): keep polling the folder and call the same rate-limited snapshot.
        - single-instance guard via pid file stored inside .git
        - -Stop stops the watcher

    Safety: local commits only. NEVER pushes, NEVER changes git config,
    NEVER uses destructive commands (reset --hard / clean -fd / push --force).

.PARAMETER Path
    Target project folder (repo root or any sub folder). Invalid values fall back to env vars / cwd.
.PARAMETER IntervalSeconds
    Minimum seconds between two automatic snapshots. Default 60. Use 0 to snapshot on every change.
.PARAMETER Watch
    Run as a background file watcher instead of a single snapshot.
.PARAMETER Stop
    Stop the watcher that is running for this repo.
.PARAMETER MaxHours
    Watcher lifetime limit in hours (default 8) so no process is left behind forever.
.PARAMETER Message
    Custom commit message.
.PARAMETER Echo
    Also print progress to the console (for manual runs). Hook runs stay silent by default.
.PARAMETER Reap
    Stop every watcher whose repository is no longer held by any CodeBuddy process
    (orphan cleanup). Never touches watchers of projects that are still open.
.PARAMETER ExitWhenWorkspaceClosed
    Watch mode only: exit automatically as soon as no CodeBuddy process keeps the
    repository as its current directory (i.e. the workspace folder was closed).
.PARAMETER WorkspaceGraceSeconds
    Watch mode + -ExitWhenWorkspaceClosed: do not run the closed-workspace check during
    the first N seconds (default 30) so a just-started watcher is never killed by mistake.
#>
[CmdletBinding()]
param(
    [string]$Path = "",
    [int]$IntervalSeconds = 60,
    [switch]$Watch,
    [switch]$Stop,
    [switch]$Reap,
    [switch]$ExitWhenWorkspaceClosed,
    [int]$WorkspaceGraceSeconds = 30,
    [double]$MaxHours = 8,
    [string]$Message = "",
    [switch]$Echo,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = "Continue"
$Tag = "[git-management]"
$LogFile = ""
$StateFile = ""
$PidFile = ""

function Write-Log {
    param([string]$Text)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    if ($LogFile) {
        try {
            if ((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 262144)) {
                $tail = Get-Content -LiteralPath $LogFile -Tail 100 -ErrorAction SilentlyContinue
                [System.IO.File]::WriteAllLines($LogFile, $tail, (New-Object System.Text.UTF8Encoding($false)))
            }
            Add-Content -LiteralPath $LogFile -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
        } catch { }
    }
    if ($Echo) { Write-Host "$Tag $Text" }
}

function Resolve-Target {
    # returns @{ Path = <resolved>; Explicit = <bool> } or $null
    $p = $Path
    $explicit = $false
    if (-not [string]::IsNullOrWhiteSpace($p) -and $p -notmatch '\$' -and (Test-Path -LiteralPath $p -PathType Container)) {
        $explicit = $true
    }
    else {
        if ($env:CODEBUDDY_PROJECT_DIR -and (Test-Path -LiteralPath $env:CODEBUDDY_PROJECT_DIR -PathType Container)) {
            $p = $env:CODEBUDDY_PROJECT_DIR
        }
        elseif ($env:CLAUDE_PROJECT_DIR -and (Test-Path -LiteralPath $env:CLAUDE_PROJECT_DIR -PathType Container)) {
            $p = $env:CLAUDE_PROJECT_DIR
        }
        elseif (Test-Path -LiteralPath (Get-Location).Path -PathType Container) {
            $p = (Get-Location).Path
        }
        else {
            return $null
        }
    }
    return @{ Path = (Resolve-Path -LiteralPath $p).Path; Explicit = $explicit }
}

function Get-RepoRoot {
    param([string]$Start)
    $p = $Start
    for ($i = 0; $i -lt 64 -and $p; $i++) {
        if (Test-Path -LiteralPath (Join-Path $p '.git')) { return $p }
        $parent = Split-Path -Parent $p
        if (-not $parent -or $parent -eq $p) { break }
        $p = $parent
    }
    return $null
}

function Test-PidAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# ------------------------------------------------ process CWD / workspace liveness helpers
# A directory cannot be deleted or renamed while a process keeps it as its current
# directory. These helpers read other processes' CWDs (via the PEB) so the watcher can
# (a) report / stop orphans, and (b) exit by itself once its workspace folder is closed.
$script:CwdReaderState = $null   # $null = not tried, $true = ready, $false = unavailable

function Initialize-CwdReader {
    if ($null -ne $script:CwdReaderState) { return $script:CwdReaderState }
    $script:CwdReaderState = $false
    if (-not $IsWindows) { return $false }
    if ([IntPtr]::Size -ne 8) { return $false }
    $src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ProcCwdReader {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("ntdll.dll")]
  static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] buf, int len, out int ret);
  [DllImport("kernel32.dll")]
  static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
  [DllImport("kernel32.dll")]
  static extern bool CloseHandle(IntPtr h);
  public static string GetCwd(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) { h = OpenProcess(0x1000, false, pid); }
    if (h == IntPtr.Zero) { return null; }
    try {
      byte[] pbi = new byte[48];
      int rl;
      if (NtQueryInformationProcess(h, 0, pbi, 48, out rl) != 0) { return null; }
      long peb = BitConverter.ToInt64(pbi, 8);
      byte[] p8 = new byte[8];
      IntPtr read;
      if (!ReadProcessMemory(h, (IntPtr)(peb + 0x20), p8, 8, out read)) { return null; }
      long pp = BitConverter.ToInt64(p8, 0);
      byte[] p16 = new byte[16];
      if (!ReadProcessMemory(h, (IntPtr)(pp + 0x38), p16, 16, out read)) { return null; }
      ushort len = BitConverter.ToUInt16(p16, 0);
      long bufPtr = BitConverter.ToInt64(p16, 8);
      if (bufPtr == 0 || len == 0) { return null; }
      if (len > 8192) { len = 8192; }
      byte[] sb = new byte[len];
      if (!ReadProcessMemory(h, (IntPtr)bufPtr, sb, len, out read)) { return null; }
      return Encoding.Unicode.GetString(sb).TrimEnd('\0');
    } finally { CloseHandle(h); }
  }
}
'@
    try {
        if (-not ('ProcCwdReader' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp | Out-Null }
        $script:CwdReaderState = $true
    }
    catch { $script:CwdReaderState = $false }
    return $script:CwdReaderState
}

function Get-ProcessCwd {
    param([int]$ProcessId)
    if (-not (Initialize-CwdReader)) { return "" }
    try {
        $c = [ProcCwdReader]::GetCwd($ProcessId)
        if ([string]::IsNullOrWhiteSpace($c)) { return "" }
        return $c.TrimEnd('\', '/')
    }
    catch { return "" }
}

function Test-PathInside {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    $c = $Child.TrimEnd('\', '/'); $p = $Parent.TrimEnd('\', '/')
    if ($c.Equals($p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CodeBuddyProcessCwds {
    # CWDs of every running CodeBuddy* process; $null means "cannot be determined"
    if (-not (Initialize-CwdReader)) { return $null }
    $list = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.ProcessName -notlike 'CodeBuddy*') { continue }
        $c = Get-ProcessCwd -ProcessId $p.Id
        if ($c) { $list += $c }
    }
    return $list
}

function Test-WorkspaceStillOpen {
    # $true while at least one CodeBuddy process keeps this folder (or a sub folder) as CWD
    param([string]$RepoPath)
    $cwds = Get-CodeBuddyProcessCwds
    if ($null -eq $cwds) { return $true }    # cannot tell -> assume open, never stop by mistake
    foreach ($c in $cwds) { if (Test-PathInside -Child $c -Parent $RepoPath) { return $true } }
    return $false
}

function Get-WatcherRepo {
    # repository of a running autosnapshot watcher: explicit -Path first, else its own CWD
    param([string]$CommandLine, [int]$ProcessId)
    if ($CommandLine -match '(?i)-Path\s+"([^"]+)"') {
        $cand = $Matches[1]
        if (Test-Path -LiteralPath $cand -PathType Container) { return (Resolve-Path -LiteralPath $cand).Path }
    }
    elseif ($CommandLine -match '(?i)-Path\s+([^\s"]+)') {
        $cand = $Matches[1]
        if (Test-Path -LiteralPath $cand -PathType Container) { return (Resolve-Path -LiteralPath $cand).Path }
    }
    return (Get-ProcessCwd -ProcessId $ProcessId)
}

function Get-WatcherProcesses {
    param([int]$ExcludePid = 0)
    $out = @()
    foreach ($proc in (Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue)) {
        if ($proc.ProcessId -eq $ExcludePid) { continue }
        $cl = [string]$proc.CommandLine
        if ($cl -notmatch 'autosnapshot\.ps1' -or $cl -notmatch '(?i)-Watch') { continue }
        $out += [pscustomobject]@{ Pid = [int]$proc.ProcessId; CommandLine = $cl }
    }
    return $out
}

function Initialize-DefaultExcludes {
    # If the project has no .gitignore of its own, put sane build-artifact excludes into
    # <gitdir>/info/exclude so auto snapshots never version .obj/.out/Debug junk.
    param([string]$GitDir, [string]$Repo)
    if (Test-Path -LiteralPath (Join-Path $Repo '.gitignore')) { return }
    $marker = '# --- git-management auto-snapshot defaults ---'
    $infoDir = Join-Path $GitDir 'info'
    $excludeFile = Join-Path $infoDir 'exclude'
    try {
        $existing = ''
        if (Test-Path -LiteralPath $excludeFile) { $existing = [System.IO.File]::ReadAllText($excludeFile) }
        if ($existing.Contains($marker)) { return }
        if (-not (Test-Path -LiteralPath $infoDir)) { New-Item -ItemType Directory -Path $infoDir -Force | Out-Null }
        $block = @(
            '',
            $marker,
            'Debug/',
            'Release/',
            '*.obj',
            '*.out',
            '*.map',
            '*.hex',
            '*.bin',
            '*.lst',
            '*.d',
            '*.d_raw',
            '*.opt',
            '*_linkInfo.xml',
            '.launches/',
            'RemoteSystemsTempFiles/',
            '.DS_Store',
            'Thumbs.db',
            '*.tmp',
            '# --- end git-management defaults ---',
            ''
        ) -join "`r`n"
        [System.IO.File]::AppendAllText($excludeFile, $block + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# ---------------------------------------------------------------- resolve target
$resolved = Resolve-Target
if (-not $resolved) { exit 0 }
$target = $resolved.Path
$explicit = $resolved.Explicit

function Test-AppInstallDir {
    # never snapshot inside an installed desktop application folder (Electron layout:
    # <app>\resources\app\package.json next to at least one <app>\*.exe), e.g. the
    # CodeBuddy install directory - a git repo there breaks the app updater.
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder)) { return $false }
    $probe = ([System.IO.Path]::GetFullPath($Folder)).TrimEnd('\', '/')
    for ($i = 0; $i -lt 4 -and $probe; $i++) {
        if (Test-Path -LiteralPath (Join-Path $probe 'resources\app\package.json')) {
            $exes = @(Get-ChildItem -LiteralPath $probe -Filter '*.exe' -File -ErrorAction SilentlyContinue)
            if ($exes.Count -gt 0) { return $true }
        }
        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }
    return $false
}

function Test-SafeToInit {
    # never create a repository in a drive root / user profile / system folder,
    # nor inside an installed application directory (see Test-AppInstallDir)
    param([string]$Folder)
    $f = $Folder.TrimEnd('\', '/')
    if ($f -match '^[A-Za-z]:$') { return $false }
    if (Test-AppInstallDir -Folder $f) { return $false }
    foreach ($b in @($env:USERPROFILE, $env:APPDATA, $env:LOCALAPPDATA, $env:ProgramData, $env:TEMP, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $bb = ([System.IO.Path]::GetFullPath($b)).TrimEnd('\', '/')
        if ($f -eq $bb) { return $false }
        if ($bb.StartsWith($f + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    foreach ($b in @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($b)) { continue }
        $bb = ([System.IO.Path]::GetFullPath($b)).TrimEnd('\', '/')
        if ($f.StartsWith($bb + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

$repo = Get-RepoRoot -Start $target
if (-not $repo) {
    if (-not (Test-SafeToInit -Folder $target)) { exit 0 }
    & git -C $target init 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { exit 0 }
    $repo = (Resolve-Path -LiteralPath $target).Path
}

# an installed application folder is never snapshotted, even if someone left a .git in it
if (Test-AppInstallDir -Folder $repo) { exit 0 }

# per-project opt-out: create <repo>/.codebuddy/autosnapshot.off to disable auto snapshots for that project
if (Test-Path -LiteralPath (Join-Path $repo '.codebuddy/autosnapshot.off')) { exit 0 }

$gitDir = (& git -C $repo rev-parse --git-dir 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($gitDir)) { exit 0 }
$gitDir = $gitDir.Trim()
if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $repo $gitDir }

$LogFile = Join-Path $gitDir 'codebuddy-autosnapshot.log'
$StateFile = Join-Path $gitDir 'codebuddy-last-autosnapshot'
$PidFile = Join-Path $gitDir 'codebuddy-autosnapshot.watch.pid'

Initialize-DefaultExcludes -GitDir $gitDir -Repo $repo

function Invoke-Snapshot {
    param([string]$Reason = "hook")

    if ($IntervalSeconds -gt 0 -and (Test-Path -LiteralPath $StateFile)) {
        $last = 0
        try { $last = [int64](((Get-Content -LiteralPath $StateFile -Raw -ErrorAction SilentlyContinue) + '').Trim()) } catch { $last = 0 }
        if ($last -gt 0) {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            if (($now - $last) -lt $IntervalSeconds) { return $false }
        }
    }

    $msg = $Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'snapshot: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

    # Use a private temporary index so the snapshot never runs git add/commit
    # against the user's real index. The commit is created directly from the tree.
    $tempIndex = Join-Path $gitDir ('codebuddy-snapshot-' + [guid]::NewGuid().ToString('N') + '.index')
    $oldIndexEnv = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $tempIndex
        $oldHead = (& git -C $repo rev-parse --verify HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $oldHead) {
            & git -C $repo read-tree $oldHead 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Write-Log 'git read-tree failed, skipped'; return $false }
        }

        & git -C $repo add -A 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Log "git add -A failed, skipped"; return $false }
        $changes = @(& git -C $repo diff --cached --name-only 2>$null | Where-Object { $_ -ne '' })
        if ($changes.Count -eq 0) { return $false }

        $tree = (& git -C $repo write-tree 2>&1 | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $tree) {
            Write-Log 'git write-tree failed, skipped'
            return $false
        }

        # If no git identity is configured (global / system / local), fall back to a neutral author
        # for this single command only - "git -c ..." never writes any config file.
        $idArgs = @()
        $idName = (& git -C $repo config user.name 2>$null | Select-Object -First 1)
        $idMail = (& git -C $repo config user.email 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($idName) -or [string]::IsNullOrWhiteSpace($idMail)) {
            $idArgs = @('-c', 'user.name=CodeBuddy Auto Snapshot', '-c', 'user.email=autosnapshot@local')
            Write-Log "no git identity found; using 'CodeBuddy Auto Snapshot <autosnapshot@local>' for this commit only (set git config --global user.name/user.email to use your own name)"
        }

        $commitArgs = @('commit-tree', $tree)
        if ($oldHead) { $commitArgs += @('-p', $oldHead) }
        $commitArgs += @('-m', $msg)
        $newHead = (& git -C $repo @idArgs @commitArgs 2>&1 | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $newHead) {
            Write-Log ("git commit-tree failed: " + $newHead)
            return $false
        }

        if ($oldHead) { & git -C $repo update-ref HEAD $newHead $oldHead 2>&1 | Out-Null }
        else { & git -C $repo update-ref HEAD $newHead 2>&1 | Out-Null }
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'git update-ref failed, skipped'
            return $false
        }
    }
    finally {
        $env:GIT_INDEX_FILE = $oldIndexEnv
        Remove-Item -LiteralPath $tempIndex -Force -ErrorAction SilentlyContinue
    }

    [System.IO.File]::WriteAllText($StateFile, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())
    $hash = (& git -C $repo rev-parse --short HEAD | Select-Object -First 1).Trim()
    Write-Log ("snapshot {0} - {1} change(s) [{2}] {3}" -f $hash, $changes.Count, $Reason, $msg)
    return $true
}

# ---------------------------------------------------------------- reap mode (orphan cleanup)
if ($Reap) {
    $stopped = 0; $kept = 0; $unknown = 0
    $openCwds = Get-CodeBuddyProcessCwds
    if ($null -eq $openCwds) {
        Write-Log "reap: cannot read process CWDs, nothing done"
        if ($Echo) { Write-Host "$Tag reap: cannot read process working directories - skipped" }
        exit 0
    }
    foreach ($w in (Get-WatcherProcesses -ExcludePid $PID)) {
        $wRepo = Get-WatcherRepo -CommandLine $w.CommandLine -ProcessId $w.Pid
        if (-not $wRepo) { $unknown++; continue }
        $open = $false
        foreach ($c in $openCwds) { if (Test-PathInside -Child $c -Parent $wRepo) { $open = $true; break } }
        if ($open) { $kept++; continue }
        Stop-Process -Id $w.Pid -Force -ErrorAction SilentlyContinue
        Write-Log ("reap: stopped orphan watcher PID {0} (repo {1})" -f $w.Pid, $wRepo)
        $stopped++
    }
    Write-Log ("reap done: stopped={0} kept={1} unknown={2}" -f $stopped, $kept, $unknown)
    if ($Echo) { Write-Host "$Tag reap: stopped=$stopped kept=$kept unknown=$unknown" }
    exit 0
}

# ---------------------------------------------------------------- stop mode
if ($Stop) {
    $stopped = $false
    if (Test-Path -LiteralPath $PidFile) {
        $oldPid = 0
        try { $oldPid = [int](((Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue) + '').Trim()) } catch { $oldPid = 0 }
        if (($oldPid -gt 0) -and ($oldPid -ne $PID) -and (Test-PidAlive -ProcessId $oldPid)) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Write-Log "watcher stopped (PID $oldPid)"
            $stopped = $true
        }
        else {
            Write-Log "stale pid file (watcher not running)"
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    # the pid file may already be gone (folder content deleted, session ended abnormally) -
    # fall back to scanning the running watcher processes and match them against this repo
    foreach ($w in (Get-WatcherProcesses -ExcludePid $PID)) {
        $wRepo = Get-WatcherRepo -CommandLine $w.CommandLine -ProcessId $w.Pid
        if (-not $wRepo) { continue }
        if ((Test-PathInside -Child $wRepo -Parent $repo) -or (Test-PathInside -Child $repo -Parent $wRepo)) {
            Stop-Process -Id $w.Pid -Force -ErrorAction SilentlyContinue
            Write-Log ("watcher stopped by scan (PID {0}, repo {1})" -f $w.Pid, $wRepo)
            $stopped = $true
        }
    }
    if ($stopped) {
        if ($Echo) { Write-Host "$Tag watcher stopped" }
    }
    else {
        Write-Log "watcher not running"
        if ($Echo) { Write-Host "$Tag watcher not running" }
    }
    exit 0
}

# ---------------------------------------------------------------- watch mode
if ($Watch) {
    if (Test-Path -LiteralPath $PidFile) {
        $oldPid = 0
        try { $oldPid = [int](((Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue) + '').Trim()) } catch { $oldPid = 0 }
        if (($oldPid -gt 0) -and (Test-PidAlive -ProcessId $oldPid)) {
            Write-Log "watcher already running (PID $oldPid), this instance exits"
            exit 0
        }
    }
    $tracked = 0
    try { $tracked = @(& git -C $repo ls-files 2>$null).Count } catch { $tracked = 0 }
    if ($tracked -gt 10000) {
        Write-Log "repo has $tracked tracked files (>10000), watcher disabled (PostToolUse hook still active)"
        exit 0
    }
    [System.IO.File]::WriteAllText($PidFile, $PID.ToString())
    Write-Log ("watch start: {0} (poll {1}s, min interval {2}s, max {3}h)" -f $repo, $PollSeconds, $IntervalSeconds, $MaxHours)
    $deadline = (Get-Date).AddHours($MaxHours)
    $graceEnd = (Get-Date).AddSeconds($WorkspaceGraceSeconds)
    $stopReason = "watch reached max lifetime"
    try {
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            # self-healing: the workspace folder was closed -> do not linger and keep the
            # folder locked as our current directory (that blocks delete/rename by hand)
            if ($ExitWhenWorkspaceClosed -and (Get-Date) -gt $graceEnd) {
                if (-not (Test-WorkspaceStillOpen -RepoPath $repo)) {
                    $stopReason = "workspace closed (no CodeBuddy process keeps it as CWD any more)"
                    if ($Echo) { Write-Host "$Tag workspace closed - watcher exits" }
                    break
                }
            }
            Invoke-Snapshot -Reason "file-change" | Out-Null
        }
        Write-Log ($stopReason + ", exiting")
    }
    finally {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# ---------------------------------------------------------------- single shot (hook)
Invoke-Snapshot -Reason "hook" | Out-Null
exit 0

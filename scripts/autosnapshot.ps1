<#
.SYNOPSIS
    git-management skill - automatic git snapshot engine (rate-limited commit + optional file watcher).

.DESCRIPTION
    Mode 1 (default, used by CodeBuddy PostToolUse hook): run one rate-limited snapshot
        1. locate target repo (-Path, else $env:CODEBUDDY_PROJECT_DIR / $env:CLAUDE_PROJECT_DIR / cwd)
        2. if less than -IntervalSeconds elapsed since the last auto snapshot, exit quietly
        3. if "git status --porcelain" shows no change, exit quietly (never create an empty commit)
        4. otherwise: git add -A + git commit -m "snapshot: yyyy-MM-dd HH:mm"

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
#>
[CmdletBinding()]
param(
    [string]$Path = "",
    [int]$IntervalSeconds = 60,
    [switch]$Watch,
    [switch]$Stop,
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

function Test-SafeToInit {
    # never create a repository in a drive root / user profile / system folder
    param([string]$Folder)
    $f = $Folder.TrimEnd('\', '/')
    if ($f -match '^[A-Za-z]:$') { return $false }
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

    $changes = @(& git -C $repo status --porcelain 2>$null | Where-Object { $_ -ne '' })
    if ($changes.Count -eq 0) { return $false }

    $msg = $Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'snapshot: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') }

    & git -C $repo add -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Log "git add -A failed, skipped"; return $false }

    # If no git identity is configured (global / system / local), fall back to a neutral author
    # for this single command only - "git -c ..." never writes any config file.
    $idArgs = @()
    $idName = (& git -C $repo config user.name 2>$null | Select-Object -First 1)
    $idMail = (& git -C $repo config user.email 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($idName) -or [string]::IsNullOrWhiteSpace($idMail)) {
        $idArgs = @('-c', 'user.name=CodeBuddy Auto Snapshot', '-c', 'user.email=autosnapshot@local')
        Write-Log "no git identity found; using 'CodeBuddy Auto Snapshot <autosnapshot@local>' for this commit only (set git config --global user.name/user.email to use your own name)"
    }

    $out = & git -C $repo @idArgs commit -m $msg 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log ("git commit failed: " + (($out | Out-String).Trim()))
        return $false
    }

    [System.IO.File]::WriteAllText($StateFile, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())
    $hash = (& git -C $repo rev-parse --short HEAD | Select-Object -First 1).Trim()
    Write-Log ("snapshot {0} - {1} change(s) [{2}] {3}" -f $hash, $changes.Count, $Reason, $msg)
    return $true
}

# ---------------------------------------------------------------- stop mode
if ($Stop) {
    if (Test-Path -LiteralPath $PidFile) {
        $oldPid = 0
        try { $oldPid = [int](((Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue) + '').Trim()) } catch { $oldPid = 0 }
        if (($oldPid -gt 0) -and ($oldPid -ne $PID) -and (Test-PidAlive -ProcessId $oldPid)) {
            Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
            Write-Log "watcher stopped (PID $oldPid)"
        }
        else {
            Write-Log "watcher not running"
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    else {
        if ($Echo) { Write-Host "$Tag watcher not running (no pid file)" }
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
    try {
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $PollSeconds
            Invoke-Snapshot -Reason "file-change" | Out-Null
        }
        Write-Log "watch reached max lifetime, exiting"
    }
    finally {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

# ---------------------------------------------------------------- single shot (hook)
Invoke-Snapshot -Reason "hook" | Out-Null
exit 0

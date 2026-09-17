<#
.SYNOPSIS
    git-management skill - SessionStart hook: start the auto-snapshot watcher and inject skill context.

.DESCRIPTION
    1. Launches autosnapshot.ps1 -Watch in a hidden background process (single instance per repo).
    2. Prints SessionStart hook JSON on stdout so the agent knows this workspace uses the
       git-management skill for automatic local snapshots.

    The injected text is read from session-context.txt (UTF-8, no BOM needed) so this script
    itself stays pure ASCII and never suffers from PowerShell script encoding problems.

.NOTES
    Hook runs must keep stdout valid JSON. Do not add extra output on stdout.
#>
[CmdletBinding()]
param(
    [string]$Path = "",
    [int]$IntervalSeconds = 60,
    [string]$ContextFile = ""
)

$ErrorActionPreference = "Continue"

$engine = Join-Path $PSScriptRoot 'autosnapshot.ps1'
$procArgs = @(
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden',
    '-File', $engine,
    '-Watch',
    '-IntervalSeconds', $IntervalSeconds
)
if (-not [string]::IsNullOrWhiteSpace($Path) -and $Path -notmatch '\$') {
    $procArgs += @('-Path', $Path)
}

if (Test-Path -LiteralPath $engine) {
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $procArgs -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
    }
    catch { }
}

if ([string]::IsNullOrWhiteSpace($ContextFile)) {
    $ContextFile = Join-Path $PSScriptRoot 'session-context.txt'
}

$ctx = ""
if (Test-Path -LiteralPath $ContextFile) {
    try { $ctx = ((Get-Content -LiteralPath $ContextFile -Raw -Encoding UTF8) + '').Trim() } catch { $ctx = "" }
}
if ([string]::IsNullOrWhiteSpace($ctx)) {
    $ctx = "This workspace uses the git-management skill for automatic local git snapshots. Follow its rules (local commits only, no empty commits, never push, never touch git config)."
}

$hookOutput = @{
    continue           = $true
    hookSpecificOutput = @{
        hookEventName      = 'SessionStart'
        additionalContext  = $ctx
    }
}

$json = $hookOutput | ConvertTo-Json -Depth 6 -Compress

# Escape every non-ASCII character as \uXXXX. Windows PowerShell 5.1 writes stdout using the
# OEM code page, which would garble Chinese text; pure-ASCII output is immune to that.
$sb = New-Object System.Text.StringBuilder
foreach ($ch in $json.ToCharArray()) {
    $code = [int]$ch
    if ($code -gt 127) { [void]$sb.AppendFormat('\u{0:x4}', $code) }
    else { [void]$sb.Append($ch) }
}
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Write-Output $sb.ToString()
exit 0

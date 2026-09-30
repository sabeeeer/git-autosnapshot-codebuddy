#requires -Version 7.0
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

# This skill targets PowerShell 7 (pwsh). Resolve the very same engine that runs this
# script so the background watcher never silently falls back to Windows PowerShell 5.1.
$psExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $psExe)) {
    $cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($cmd) { $psExe = $cmd.Source }
}
if (-not (Test-Path -LiteralPath $psExe)) { $psExe = 'pwsh.exe' }

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
        Start-Process -FilePath $psExe -ArgumentList $procArgs -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
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

# ── ★ 自动体检结论注入（用户要求：这些检查以后自动跑，不要每次让他开口）──────────
#   策略：优先读"上一次体检报告"的 SUMMARY 行（0 成本、瞬时）；
#         只有报告不存在时（例如新机还没跑过备份）才现场跑一次 -Quick（不联网）。
#   ⚠ 这里**绝不能**让 health_check 的输出漏到 stdout —— hook 的 stdout 必须是合法 JSON。
$healthLine = ""
try {
    $hcScript = Join-Path $PSScriptRoot 'health_check.ps1'
    if (Test-Path -LiteralPath $hcScript) {
        $hcLog = Join-Path $HOME 'CodeBuddy\skills-auto-upload\logs\health_last.txt'
        if (Test-Path -LiteralPath $hcLog) {
            $item = Get-Item -LiteralPath $hcLog -ErrorAction SilentlyContinue
            $m = Select-String -LiteralPath $hcLog -Pattern '^SUMMARY: ' -ErrorAction SilentlyContinue | Select-Object -Last 1
            if ($m) { $healthLine = ($m.Line -replace '^SUMMARY: ', '').Trim() }
            if ($healthLine -and $item) {
                $healthLine = $healthLine + "（报告生成于 " + $item.LastWriteTime.ToString('MM-dd HH:mm') + "；需要现跑一次就让我执行该脚本）"
            }
        }
        if ([string]::IsNullOrWhiteSpace($healthLine)) {
            $healthLine = (& $psExe -NoProfile -ExecutionPolicy Bypass -File $hcScript -Quick -SummaryOnly 2>$null | Out-String).Trim()
        }
    }
}
catch { $healthLine = "" }

if (-not [string]::IsNullOrWhiteSpace($healthLine)) {
    $ctx = $ctx + "`n`n【本机自动体检结论（由 sessionstart hook 注入，用户无需开口）】`n" + $healthLine
    $ctx = $ctx + "`n明细或需要重新体检：pwsh -NoProfile -File `<git-management>`/scripts/health_check.ps1（-Quick 不联网）"
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

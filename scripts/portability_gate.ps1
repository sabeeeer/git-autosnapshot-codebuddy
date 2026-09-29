#!/usr/bin/env pwsh
#requires -Version 7.0
<#
portability_gate.ps1 —— 可迁移性门禁（上传 GitHub 前的强制检查）

═══════════════════════════════════════════════════════════════════════════
为什么有这个东西

用户要求（2026-09-29）：**本机任何要上传到 GitHub 的内容，都必须"完完全全可迁移"** ——
以后换平台（CodeBuddy → Codex/Claude/Cursor/…）、换账号、换电脑，
只靠"登录 GitHub"就能迁移过来使用。规范正文见仓库根 `PORTABILITY.md`。

本脚本是该要求的**技术落点**：把"规范"变成"可执行的检查"。
它被三处调用，形成三道闸：
  ① 手工跑 / AI 跑      —— 随时自检
  ② git pre-push hook   —— 任何 git push 前自动执行，不通过则**拒绝推送**（硬拦截）
  ③ run_backup.ps1      —— 定时上传脚本推送前先过闸
（提供 install_gate.ps1 一键安装 ②）

检查项（对应 PORTABILITY.md 的条款）
  [拦截] 硬编码凭据：token / 私钥 / 明码 password
  [拦截] 机器绑定路径：C:\Users\<具体用户名>（且未豁免）
  [拦截] 敏感文件：.env / *.pem / *.key / id_rsa* / *.pfx / gh_token.txt
  [拦截] 缺 RECOVER.md（仓库根必须存在 —— 它是"登录 GitHub 后的唯一入口"）
  [警告] 缺 README.md
  [警告] 大文件 > 50MB
  [警告] 关键脚本/目录名含非 ASCII 字符

豁免机制（避免误伤"本职需要记录旧机样子"的工具）
  1) 仓库根放 `.portability-allow` —— 每行一个正则，匹配到的**文件相对路径**跳过全部检查
     例：`^skills/new-pc-migration/`（迁移工具必须记录旧机盘符）
  2) 文件内写注释 `portability:ignore-path` —— 该文件跳过"路径"检查（凭据检查仍生效）

退出码：0 = 通过（可能带警告）；1 = 有拦截级问题；2 = 仅警告
用法：
  pwsh -NoProfile -File portability_gate.ps1 -RepoPath <仓库>
  pwsh -NoProfile -File portability_gate.ps1 -RepoPath <仓库> -ListFiles
  pwsh -NoProfile -File portability_gate.ps1 -RepoPath <仓库> -AllowPattern '^skills/new-pc-migration/'
═══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
    [string]$RepoPath = '.',
    [string[]]$AllowPattern = @(),      # 追加豁免（正则，针对相对路径）
    [switch]$ListFiles,                 # 打印将被检查的文件清单
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

# ── 输出工具 ────────────────────────────────────────────────
$script:blockers = New-Object System.Collections.Generic.List[string]
$script:warnings = New-Object System.Collections.Generic.List[string]
$script:checkedCount = 0

function Say($msg, $color = 'Gray') { if (-not $Quiet) { Write-Host $msg -ForegroundColor $color } }
function Head($msg) { Say ''; Say "== $msg" 'Cyan' }
function Blocker($msg) { $script:blockers.Add($msg); Say ("  ✖ " + $msg) 'Red' }
function Warn($msg) { $script:warnings.Add($msg); Say ("  ⚠ " + $msg) 'Yellow' }
function Pass($msg) { Say ("  ✓ " + $msg) 'Green' }

# ── 定位仓库 ────────────────────────────────────────────────
if (-not (Test-Path -LiteralPath $RepoPath)) {
    Write-Host "ERROR: 仓库路径不存在: $RepoPath" -ForegroundColor Red
    exit 1
}
$repo = (Resolve-Path -LiteralPath $RepoPath).Path
$gitDir = Join-Path $repo '.git'
if (-not (Test-Path -LiteralPath $gitDir)) {
    Write-Host "ERROR: 不是 git 仓库（缺 .git）: $repo" -ForegroundColor Red
    exit 1
}

Say ''
Say '════════════════════════════════════════════════' 'DarkCyan'
Say '  可迁移性门禁 portability_gate' 'Cyan'
Say "  仓库: $repo" 'DarkGray'
Say '════════════════════════════════════════════════' 'DarkCyan'

# ── 读豁免清单 ──────────────────────────────────────────────
$allowFile = Join-Path $repo '.portability-allow'
$allowPatterns = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $allowFile) {
    Get-Content -LiteralPath $allowFile -Encoding utf8 |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
        ForEach-Object { $allowPatterns.Add($_.Trim()) }
    Say ("  豁免清单: .portability-allow（{0} 条规则）" -f $allowPatterns.Count) 'DarkGray'
}
foreach ($p in $AllowPattern) { $allowPatterns.Add($p) }

function Is-Allowed([string]$rel) {
    foreach ($p in $allowPatterns) {
        try { if ($rel -match $p) { return $true } } catch { }
    }
    return $false
}

# ── 收集待检查文件（git 跟踪的文本文件）────────────────────
$tracked = @(git -C $repo ls-files 2>$null)
if (-not $tracked -or $tracked.Count -eq 0) {
    Say '  仓库里没有 git 跟踪的文件（全新仓库？）' 'Yellow'
}

$textExt = @('.md', '.txt', '.ps1', '.psm1', '.py', '.js', '.ts', '.json', '.yml', '.yaml', '.toml',
    '.ini', '.cfg', '.conf', '.c', '.h', '.cpp', '.cs', '.java', '.sh', '.bat', '.cmd', '.xml', '.csv', '.sql', '.cmd')
$binExt = @('.exe', '.dll', '.zip', '.7z', '.rar', '.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf',
    '.docx', '.xlsx', '.pptx', '.mp3', '.mp4', '.bin', '.lib', '.obj', '.so', '.dylib', '.pyc')

$files = New-Object System.Collections.Generic.List[object]
foreach ($rel in $tracked) {
    $full = Join-Path $repo $rel
    if (-not (Test-Path -LiteralPath $full)) { continue }
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    $isText = ($textExt -contains $ext) -or ($ext -eq '')
    $files.Add([pscustomobject]@{ Rel = $rel; Full = $full; Ext = $ext; IsText = $isText })
}
Say ("  待检查文件: {0} 个（git 跟踪）" -f $files.Count) 'DarkGray'
if ($ListFiles) { $files | ForEach-Object { Say ("      " + $_.Rel) 'DarkGray' } }

# ── 检查 1：硬编码凭据 ──────────────────────────────────────
Head '检查 1：硬编码凭据'
$credHit = 0
$textFiles = @($files | Where-Object { $_.IsText })
Say ("  文本文件 {0} 个（其中被豁免跳过 {1} 个）" -f $textFiles.Count, (@($textFiles | Where-Object { Is-Allowed $_.Rel }).Count)) 'DarkGray'
foreach ($f in $textFiles) {
    if (Is-Allowed $f.Rel) { continue }
    $script:checkedCount++
    $lines = @(Get-Content -LiteralPath $f.Full -Encoding utf8 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        if ($ln -match 'ghp_[A-Za-z0-9]{20,}' -or $ln -match 'github_pat_[A-Za-z0-9_]{20,}' -or
            $ln -match 'gho_[A-Za-z0-9]{20,}' -or $ln -match '-----BEGIN [A-Z ]*PRIVATE KEY-----' -or
            $ln -match '(?i)password\s*[:=]\s*[''"][^''"\s]{4,}') {
            Blocker ("硬编码凭据: {0}:{1}  {2}" -f $f.Rel, ($i + 1), $ln.Trim().Substring(0, [Math]::Min(60, $ln.Trim().Length)))
            $credHit++
        }
    }
}
if ($credHit -eq 0) { Pass '未发现硬编码凭据' }

# ── 检查 2：机器绑定路径 ────────────────────────────────────
Head '检查 2：机器绑定路径（C:\Users\<某人> 等）'
$pathHit = 0
foreach ($f in $files) {
    if (-not $f.IsText) { continue }
    if (Is-Allowed $f.Rel) { continue }
    $lines = Get-Content -LiteralPath $f.Full -Encoding utf8 -ErrorAction SilentlyContinue
    if (-not $lines) { continue }
    $hasIgnoreMark = ($lines -join "`n") -match 'portability:ignore-path'
    if ($hasIgnoreMark) { continue }
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        # 机器绑定：盘符 + Users\<具体用户名>（排除占位符/变量写法）
        if ($ln -match '[A-Za-z]:\\+Users\\+\w+' -and
            $ln -notmatch '\\\\Users\\\\|%USERPROFILE%|\$env:USERPROFILE|<用户名>|<user>|<name>|\.\.\.') {
            Warn ("路径可疑: {0}:{1}  {2}" -f $f.Rel, ($i + 1), $ln.Trim().Substring(0, [Math]::Min(70, $ln.Trim().Length)))
            $pathHit++
            if ($pathHit -ge 40) { Warn '（已达 40 条上限，其余从略）'; break }
        }
    }
    if ($pathHit -ge 40) { break }
}
if ($pathHit -eq 0) { Pass '未发现机器绑定的绝对路径' }
else {
    Warn ("共 {0} 处 —— 若是**文档示例**或**迁移工具本职**，请在仓库根 .portability-allow 里豁免（例：^skills/new-pc-migration/）" -f $pathHit)
}

# ── 检查 3：敏感文件 ────────────────────────────────────────
Head '检查 3：敏感文件'
$sensHit = 0
foreach ($f in $files) {
    if (Is-Allowed $f.Rel) { continue }
    $name = [IO.Path]::GetFileName($f.Rel)
    if ($name -match '^(\.env|\.env\..*|id_rsa.*|id_ed25519.*|gh_token\.txt)$' -or
        $f.Ext -in @('.pem', '.key', '.pfx', '.p12', '.keystore', '.jks')) {
        Blocker ("敏感文件不应入库: " + $f.Rel)
        $sensHit++
    }
}
if ($sensHit -eq 0) { Pass '未发现敏感文件' }

# ── 检查 4/5：必需文件 ──────────────────────────────────────
Head '检查 4：恢复入口 RECOVER.md'
$hasRecover = @($files | Where-Object { $_.Rel -eq 'RECOVER.md' }).Count -gt 0
if ($hasRecover) { Pass 'RECOVER.md 存在（登录 GitHub 后的唯一入口）' }
else { Blocker '仓库根缺少 RECOVER.md —— 换机/换平台时没有恢复入口（见 PORTABILITY.md 条款 5）' }

Head '检查 5：README.md'
$hasReadme = @($files | Where-Object { $_.Rel -match '^(README|readme)\.md$' }).Count -gt 0
if ($hasReadme) { Pass 'README.md 存在' }
else { Warn '缺少 README.md（建议补一个简短说明）' }

# ── 检查 6：大文件 ──────────────────────────────────────────
Head '检查 6：大文件（> 50MB）'
$bigHit = 0
foreach ($f in $files) {
    $len = (Get-Item -LiteralPath $f.Full).Length
    if ($len -gt 50MB) { Warn ("大文件 {0:N1} MB: {1}" -f ($len / 1MB), $f.Rel); $bigHit++ }
}
if ($bigHit -eq 0) { Pass '无超限大文件' }

# ── 检查 7：非 ASCII 关键路径 ───────────────────────────────
Head '检查 7：关键脚本/目录名的 ASCII 规范'
$naHit = 0
foreach ($f in $files) {
    if ($f.Ext -in @('.ps1', '.psm1', '.py', '.sh', '.bat', '.cmd')) {
        $base = [IO.Path]::GetFileNameWithoutExtension($f.Rel)
        if ($base -match '[^\x00-\x7F]') { Warn ("脚本文件名含非 ASCII: " + $f.Rel); $naHit++ }
    }
}
if ($naHit -eq 0) { Pass '脚本文件名均为 ASCII' }

# ── 结论 ────────────────────────────────────────────────────
Head '结论'
Say ("  检查文件: {0} 个 ｜ 拦截项: {1} ｜ 警告项: {2}" -f $files.Count, $script:blockers.Count, $script:warnings.Count) 'White'

if ($script:blockers.Count -gt 0) {
    Say ''
    Say '  ✖ 门禁未通过 —— 禁止上传到 GitHub。' 'Red'
    Say '    处置：① 修掉上面的"拦截"项；② 若确属合理（如迁移工具本职），' 'Red'
    Say '          在仓库根 .portability-allow 里加正则豁免，或文件内写 portability:ignore-path。' 'Red'
    Say ''
    exit 1
}
elseif ($script:warnings.Count -gt 0) {
    Say ''
    Say '  ⚠ 门禁通过（有警告）—— 允许上传，但建议逐条确认。' 'Yellow'
    Say ''
    exit 2
}
else {
    Say ''
    Say '  ✓ 门禁通过 —— 内容满足可迁移性要求。' 'Green'
    Say ''
    exit 0
}

#requires -Version 7.0
<#
check_sync_status.ps1 —— 一次看清所有 skill 的"最新状态"

═══════════════════════════════════════════════════════════════════════════
★ 为什么需要这个脚本（血泪教训，务必先读）

  本机有 **三套互相独立** 的上传 / 备份体系。只查其中一个，会得出
  "已经同步到最新"的错误结论 —— 这是真实踩过的坑：

    ① **各 skill 自己的 git 仓库**
       例：ti-c2000-ccs-auto → git@github.com:sabeeeer/DSP-auto-debug.git
       只有 2 个 skill 是这种（ti-c2000-ccs-auto、git-management）

    ② **skills-auto-upload 自动上传系统**（每天 13:50 automation + 13:52 计划任务）
       → 私有仓库 sabeeeer/codebuddy-skills
       ⚠ **只上传 state.json 里 tracked 清单内的 skill**（本机是 6 个 / 共 30 个）
       ⚠ 这个仓库是 private，在 GitHub 上不登录看不到，容易误以为"没传上去"

    ③ **CodeBuddy 本地快照 hooks**（git-management 提供）
       → 只做本地 commit，**从不 push**（脚本内明写 "NEVER pushes"）

  判断"是否最新"的唯一正确入口是：
    · <UploadRoot>\config.json  → github_repo / visibility（管到哪里）
    · <UploadRoot>\state.json   → tracked（纳管哪些）/ last_upload_at（上次何时传）
    · <UploadRoot>\logs\last_result.txt → 上次结果（成功 / 失败 / commit）
  先读这些，再谈比对。不要凭"git status 显示 origin/main 同步"就下结论。

★ 比对方式
  用 **SHA256 内容哈希**（不是文件大小！）。大小相同但内容不同的改动，
  以及"同名文件被替换"的情况，只有哈希能发现。

用法：
  pwsh -NoProfile -File check_sync_status.ps1              # 概览
  pwsh -NoProfile -File check_sync_status.ps1 -Detail      # 明细（列出差异文件）
  pwsh -NoProfile -File check_sync_status.ps1 -SkillsRoot <路径> -UploadRoot <路径>
═══════════════════════════════════════════════════════════════════════════
#>
param(
    [string]$SkillsRoot = (Join-Path $env:USERPROFILE '.codebuddy\skills'),
    [string]$UploadRoot = (Join-Path $env:USERPROFILE 'CodeBuddy\skills-auto-upload'),
    [switch]$Detail
)

$ErrorActionPreference = 'Continue'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

# ── 工具：目录内容哈希（排除 .git；文件名 + 内容 SHA256，排序后整体再哈希）──
function Get-TreeHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } |
        ForEach-Object {
            $rel = $_.FullName.Substring($Path.Length).TrimStart('\')
            $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
            "$rel|$h"
        } | Sort-Object
    if (-not $lines) { return '(empty)' }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return (($sha | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ── 工具：列出两个目录的差异文件 ──
function Get-TreeDiff {
    param([string]$Left, [string]$Right, [int]$Max = 8)
    $diffs = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Left)) { return @('(左目录不存在)') }
    Get-ChildItem -LiteralPath $Left -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
            $rel = $_.FullName.Substring($Left.Length).TrimStart('\')
            $tgt = Join-Path $Right $rel
            if (-not (Test-Path -LiteralPath $tgt)) {
                $diffs.Add("仅本地: $rel")
            }
            else {
                $h1 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                $h2 = (Get-FileHash -LiteralPath $tgt -Algorithm SHA256).Hash
                if ($h1 -ne $h2) { $diffs.Add("内容不同: $rel") }
            }
        }
    if (Test-Path -LiteralPath $Right) {
        Get-ChildItem -LiteralPath $Right -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
                $rel = $_.FullName.Substring($Right.Length).TrimStart('\')
                if (-not (Test-Path -LiteralPath (Join-Path $Left $rel))) { $diffs.Add("仅镜像: $rel") }
            }
    }
    if ($diffs.Count -eq 0) { return @() }
    if ($diffs.Count -gt $Max) { return @($diffs[0..($Max - 1)]) + @("... 其余 $($diffs.Count - $Max) 项") }
    return $diffs
}

$now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Write-Host ""
Write-Host "═══════════ skill 同步状态体检  $now ═══════════"
Write-Host ""

# ═══ ① 自动上传系统 ═══
Write-Host "【① 自动上传系统（skills-auto-upload）】"
$cfgPath = Join-Path $UploadRoot 'config.json'
$stPath = Join-Path $UploadRoot 'state.json'
$tracked = @()
if (Test-Path -LiteralPath $cfgPath) {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding utf8 | ConvertFrom-Json
    Write-Host ("   目标仓库 : {0}  ({1})" -f $cfg.github_repo, $(if ($cfg.visibility) { $cfg.visibility } else { '-' }))
    Write-Host ("   代理     : {0}" -f $(if ($cfg.proxy) { $cfg.proxy } else { '(未设置)' }))
    if (Test-Path -LiteralPath $stPath) {
        $st = Get-Content -LiteralPath $stPath -Raw -Encoding utf8 | ConvertFrom-Json
        $tracked = @($st.tracked)
        $upAt = if ($st.last_upload_at) { (Get-Date '1970-01-01').AddSeconds([double]$st.last_upload_at).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { '-' }
        Write-Host ("   纳管清单 : {0} 个 —— {1}" -f $tracked.Count, ($tracked -join ', '))
        Write-Host ("   上次上传 : {0}" -f $upAt)
        if ($st.api_commit) { Write-Host ("   远程提交 : " + $st.api_commit.Substring(0, [Math]::Min(10, $st.api_commit.Length))) }
    }
    $lr = Join-Path $UploadRoot 'logs\last_result.txt'
    if (Test-Path -LiteralPath $lr) {
        Write-Host "   上次结果 :"
        Get-Content -LiteralPath $lr -Encoding utf8 | ForEach-Object { Write-Host ("      " + $_) }
    }
}
else {
    Write-Host "   (未安装自动上传系统：$UploadRoot)"
}
Write-Host ""

# ═══ ② 本地 skills vs 镜像 repo ═══
Write-Host "【② 本地 skills vs 上传镜像 repo】"
$mirror = Join-Path $UploadRoot 'repo\skills'
if (-not (Test-Path -LiteralPath $mirror)) {
    Write-Host "   (镜像目录不存在：$mirror)"
}
else {
    $localNames = @(Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $ok = 0; $diff = @(); $untracked = @()
    foreach ($n in $localNames) {
        $lp = Join-Path $SkillsRoot $n
        $mp = Join-Path $mirror $n
        if (-not (Test-Path -LiteralPath $mp)) { $untracked += $n; continue }
        $h1 = Get-TreeHash $lp; $h2 = Get-TreeHash $mp
        if ($h1 -eq $h2) { $ok++ } else { $diff += $n }
    }
    Write-Host ("   本地共 {0} 个 skill｜与镜像一致 {1} 个｜有落差 {2} 个｜未纳管 {3} 个" -f $localNames.Count, $ok, $diff.Count, $untracked.Count)
    if ($diff.Count -gt 0) {
        Write-Host "   ⚠ 与镜像有落差（改动尚未上传）:"
        foreach ($n in $diff) {
            Write-Host ("      · " + $n)
            if ($Detail) {
                Get-TreeDiff (Join-Path $SkillsRoot $n) (Join-Path $mirror $n) | ForEach-Object { Write-Host ("          " + $_) }
            }
        }
    }
    if ($untracked.Count -gt 0) {
        Write-Host ("   ◻ 未纳管（永不自动上传）: " + ($untracked -join ', '))
    }
}
Write-Host ""

# ═══ ③ 各 skill 自己的 git 仓库 ═══
Write-Host "【③ 各 skill 自带的 git 仓库】"
$found = 0
Get-ChildItem -LiteralPath $SkillsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $gitDir = Join-Path $_.FullName '.git'
    if (Test-Path -LiteralPath $gitDir) {
        $found++
        $rm = (git -C $_.FullName remote get-url origin 2>&1)
        $sb = (git -C $_.FullName status -sb 2>&1 | Select-Object -First 1)
        $un = @(git -C $_.FullName status --short 2>&1 | Where-Object { $_ -match '\S' })
        Write-Host ("   · " + $_.Name)
        Write-Host ("       remote : " + $rm)
        Write-Host ("       状态   : " + $sb)
        if ($un.Count -gt 0) {
            Write-Host ("       ⚠ 未提交 : " + $un.Count + " 个")
            if ($Detail) { $un | ForEach-Object { Write-Host ("           " + $_) } }
        }
        else {
            Write-Host "       未提交 : 无"
        }
    }
}
if ($found -eq 0) { Write-Host "   (没有 skill 自建 git 仓库)" }
Write-Host ""

Write-Host "═══════════════════════════════════════════════════"
Write-Host "提示：本机三套体系各自独立，'某个仓库同步'不等于'全部最新'。"
Write-Host "      判断依据以 ① 的 config.json / state.json / last_result.txt 为准。"
Write-Host ""

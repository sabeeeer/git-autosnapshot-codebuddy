#!/usr/bin/env pwsh
#requires -Version 7.0
<#
install_gate.ps1 —— 安装 / 卸载「可迁移性门禁」的 git pre-push hook

作用：给仓库装一个 `pre-push` hook，**任何 `git push` 之前都会自动跑 portability_gate.ps1**，
不通过就**拒绝推送**。这样"上传到 GitHub 的内容必须可迁移"就成了一条**技术约束**，
而不是只写在文档里靠自觉。

hook 的实际行为（装好后）：
  · 推送前自动检查：硬编码凭据 / 机器绑定路径 / 敏感文件 / 缺 RECOVER.md / 大文件 / 非 ASCII 脚本名
  · 有"拦截级"问题 → 打印原因并**中止推送**（`git push` 返回非 0）
  · 只有警告 → 放行，但会打印警告
  · 可用 `git push --no-verify` 临时绕过（应急用；绕过记录建议事后补检）

用法：
  pwsh -NoProfile -File install_gate.ps1 -Status              # 看哪些仓库已装
  pwsh -NoProfile -File install_gate.ps1 -Path <仓库>          # 给一个仓库装
  pwsh -NoProfile -File install_gate.ps1 -All                  # 给所有"已知仓库"装
  pwsh -NoProfile -File install_gate.ps1 -Path <仓库> -Uninstall

"已知仓库"包括：skills-auto-upload 的镜像仓库，以及 ~/.codebuddy/skills/*/ 里自带的 git 仓库。
═══════════════════════════════════════════════════════════════════════════
#>
[CmdletBinding()]
param(
    [string[]]$Path = @(),
    [switch]$All,
    [switch]$Status,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

$gatePath = Join-Path $PSScriptRoot 'portability_gate.ps1'
$marker = '# >>> portability-gate (managed by install_gate.ps1) >>>'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

function Get-KnownRepos {
    $list = New-Object System.Collections.Generic.List[string]
    $mirror = Join-Path $HOME 'CodeBuddy/skills-auto-upload/repo'
    if (Test-Path -LiteralPath (Join-Path $mirror '.git')) { $list.Add($mirror) }
    $skillsRoot = Join-Path $HOME '.codebuddy/skills'
    if (Test-Path -LiteralPath $skillsRoot) {
        Get-ChildItem -LiteralPath $skillsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) { $list.Add($_.FullName) }
        }
    }
    return $list
}

function New-HookContent {
    # POSIX sh —— git 在 Windows 下也用 sh 执行 hook（Git for Windows 自带）
    $gateUnix = $gatePath -replace '\\', '/'
    @"
#!/bin/sh
$marker
# 可迁移性门禁：任何 git push 前检查"要上传的内容是否可迁移"。
# 规范见仓库根 PORTABILITY.md；检查逻辑见 portability_gate.ps1。
# 应急绕过：git push --no-verify

PWSH=""
if command -v pwsh >/dev/null 2>&1; then
    PWSH="pwsh"
elif [ -x "/c/Program Files/PowerShell/7/pwsh.exe" ]; then
    PWSH="/c/Program Files/PowerShell/7/pwsh.exe"
fi

if [ -z "`$PWSH" ]; then
    echo "[portability-gate] 跳过检查（未找到 pwsh；请安装 PowerShell 7）" >&2
    exit 0
fi

ROOT=`$(git rev-parse --show-toplevel 2>/dev/null)
"`$PWSH" -NoProfile -ExecutionPolicy Bypass -File "$gateUnix" -RepoPath "`$ROOT" -Quiet
RC=`$?

if [ "`$RC" = "1" ]; then
    echo "" >&2
    echo "❌ 可迁移性门禁未通过 —— 推送已被拒绝。" >&2
    echo "   查看详情：" >&2
    echo "     `$PWSH -NoProfile -File \"$gateUnix\" -RepoPath \"`$ROOT\"" >&2
    echo "   豁免：仓库根加 .portability-allow（每行一个正则），或文件内写 portability:ignore-path" >&2
    echo "" >&2
    exit 1
fi
exit 0
# <<< portability-gate <<<
"@
}

function Invoke-Install([string]$repo, [bool]$remove) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) {
        Say ("  ✖ 不是 git 仓库: $repo") 'Red'; return $false
    }
    $hooksDir = Join-Path $repo '.git/hooks'
    if (-not (Test-Path -LiteralPath $hooksDir)) { New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null }
    $hookFile = Join-Path $hooksDir 'pre-push'

    if ($remove) {
        if ((Test-Path -LiteralPath $hookFile) -and ((Get-Content -LiteralPath $hookFile -Raw -Encoding utf8) -match 'portability-gate')) {
            Remove-Item -LiteralPath $hookFile -Force
            Say ("  ✔ 已卸载: " + $repo) 'Green'
            return $true
        }
        Say ("  · 未安装（跳过）: " + $repo) 'DarkGray'
        return $false
    }

    # 已存在非本门禁的 hook → 备份后再覆盖
    if (Test-Path -LiteralPath $hookFile) {
        $existing = Get-Content -LiteralPath $hookFile -Raw -Encoding utf8
        if ($existing -match 'portability-gate') {
            # 已装：刷新内容（脚本可能升级过）
        }
        else {
            $bak = "$hookFile.bak-" + (Get-Date -Format 'yyyyMMddHHmmss')
            Copy-Item -LiteralPath $hookFile -Destination $bak -Force
            Say ("  ⚠ 已有 pre-push hook，已备份为 " + [IO.Path]::GetFileName($bak)) 'Yellow'
        }
    }

    New-HookContent | Set-Content -LiteralPath $hookFile -Encoding utf8 -NoNewline
    Say ("  ✔ 已安装: " + $repo) 'Green'
    return $true
}

function Show-Status([string[]]$repos) {
    Say ''
    Say '已装状态：' 'Cyan'
    foreach ($r in $repos) {
        $hookFile = Join-Path $r '.git/hooks/pre-push'
        $installed = (Test-Path -LiteralPath $hookFile) -and ((Get-Content -LiteralPath $hookFile -Raw -Encoding utf8 -ErrorAction SilentlyContinue) -match 'portability-gate')
        $mark = if ($installed) { '✔ 已装' } else { '✖ 未装' }
        $color = if ($installed) { 'Green' } else { 'DarkGray' }
        Say ("  {0}  {1}" -f $mark, $r) $color
    }
}

# ── 主流程 ──────────────────────────────────────────────────
Say ''
Say '════════════════════════════════════════════════' 'DarkCyan'
Say '  可迁移性门禁 安装器（install_gate.ps1）' 'Cyan'
Say '════════════════════════════════════════════════' 'DarkCyan'

if (-not (Test-Path -LiteralPath $gatePath)) {
    Say ("  ✖ 找不到检查器: $gatePath") 'Red'; exit 1
}
Say ("  检查器: $gatePath") 'DarkGray'

$repos = New-Object System.Collections.Generic.List[string]
if ($All -or $Path.Count -eq 0) { Get-KnownRepos | ForEach-Object { $repos.Add($_) } }
foreach ($p in $Path) { $repos.Add((Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).Path) }
$repos = @($repos | Where-Object { $_ } | Select-Object -Unique)

if ($Status) {
    Show-Status $repos
    Say ''
    exit 0
}

if ($repos.Count -eq 0) { Say '  没有目标仓库（用 -Path <仓库> 或 -All）' 'Yellow'; exit 0 }

Say ''
Say ("目标仓库 {0} 个：" -f $repos.Count) 'White'
$done = 0
foreach ($r in $repos) { if (Invoke-Install $r ([bool]$Uninstall)) { $done++ } }

Say ''
Say ("完成：{0} 个仓库{1}。" -f $done, $(if ($Uninstall) { '已卸载' } else { '已装上门禁' })) 'Green'
Say ''
Say '效果：这些仓库下次 git push 时会自动跑可迁移性检查，不通过则拒绝推送。' 'White'
Say '      手工检查：pwsh -NoProfile -File "' -NoNewline 'DarkGray'
Say ($gatePath + '" -RepoPath <仓库>') 'DarkGray'
Say '      应急绕过：git push --no-verify' 'DarkGray'
Say ''

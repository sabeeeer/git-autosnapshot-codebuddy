#requires -Version 7.0
<#
.SYNOPSIS
    对指定目录做一次本地 Git 版本快照（不推送远程）。

.DESCRIPTION
    - 无 .git 时自动 git init
    - 用 git status --porcelain 判断有无改动；无改动则直接退出（绝不产生空提交）
    - 有改动则 git add -A 并提交，默认信息 "snapshot: yyyy-MM-dd HH:mm"
    - 只做本地操作：不推送远程、不修改 git config、不做任何破坏性操作

.PARAMETER Path
    目标目录，默认当前目录。

.PARAMETER Message
    自定义提交信息。定时快照建议传 "auto-snapshot yyyy-MM-dd"。

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File snapshot.ps1 -Path "E:\proj\demo"

.EXAMPLE
    pwsh -ExecutionPolicy Bypass -File snapshot.ps1 -Message "auto-snapshot 2026-09-16"
#>
param(
    [string]$Path = ".",
    [string]$Message = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Output "[git-management] 错误: 目录不存在 -> $Path"
    exit 1
}

Push-Location -LiteralPath $Path
try {
    if (-not (Test-Path -LiteralPath (Join-Path (Get-Location).Path ".git"))) {
        git init | Out-Null
        Write-Output "[git-management] 已初始化仓库: $((Get-Location).Path)"
    }

    $changes = @(git status --porcelain | Where-Object { $_ -ne "" })
    if ($changes.Count -eq 0) {
        Write-Output "[git-management] 无改动，跳过提交（不创建空提交）。"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "snapshot: " + (Get-Date -Format "yyyy-MM-dd HH:mm")
    }

    git add -A
    if ($LASTEXITCODE -ne 0) { throw "git add -A 失败" }

    $commitOut = git commit -m $Message 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output "[git-management] 提交失败:"
        Write-Output $commitOut
        Write-Output "[git-management] 若提示缺少身份信息，请自行执行（本脚本不会替你修改 git config）:"
        Write-Output '  git config --global user.name  "你的名字"'
        Write-Output '  git config --global user.email "你的邮箱"'
        exit 1
    }

    $hash = (git rev-parse --short HEAD).Trim()
    Write-Output "[git-management] 快照完成: $hash  ($($changes.Count) 项改动)"
    Write-Output "[git-management] 提交信息: $Message"
    Write-Output "[git-management] 仅本地提交，未推送远程。"
}
finally {
    Pop-Location
}

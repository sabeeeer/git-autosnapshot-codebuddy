#requires -Version 7.0
<#
.SYNOPSIS
    对指定目录做一次本地 Git 版本快照（不推送远程）。

.DESCRIPTION
    - 无 .git 时自动 git init
    - 用临时 index 扫描工作区；无改动则直接退出（绝不产生空提交）
    - 有改动则用临时 index 创建 snapshot commit；不执行会改写真实 index 的 `git add`
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

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "snapshot: " + (Get-Date -Format "yyyy-MM-dd HH:mm")
    }

    $gitDir = (git rev-parse --git-dir).Trim()
    if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path (Get-Location).Path $gitDir }
    $tempIndex = Join-Path $gitDir ('codebuddy-snapshot-' + [guid]::NewGuid().ToString('N') + '.index')
    $oldIndex = $env:GIT_INDEX_FILE
    try {
        $env:GIT_INDEX_FILE = $tempIndex
        $oldHead = (git rev-parse --verify HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $oldHead) {
            git read-tree $oldHead
            if ($LASTEXITCODE -ne 0) { throw 'git read-tree HEAD 失败' }
        }
        git add -A
        if ($LASTEXITCODE -ne 0) { throw 'git add -A 失败' }

        $changes = @(git diff --cached --name-only | Where-Object { $_ -ne '' })
        if ($changes.Count -eq 0) {
            Write-Output "[git-management] 无改动，跳过提交（不创建空提交）。"
            exit 0
        }

        $tree = (git write-tree).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $tree) { throw 'git write-tree 失败' }

        $idArgs = @()
        $idName = (git config user.name 2>$null | Select-Object -First 1)
        $idMail = (git config user.email 2>$null | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($idName) -or [string]::IsNullOrWhiteSpace($idMail)) {
            $idArgs = @('-c', 'user.name=CodeBuddy Auto Snapshot', '-c', 'user.email=autosnapshot@local')
        }

        $commitArgs = @('commit-tree', $tree)
        if ($oldHead) { $commitArgs += @('-p', $oldHead) }
        $commitArgs += @('-m', $Message)
        $newHead = (git @idArgs @commitArgs 2>&1 | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $newHead) {
            Write-Output '[git-management] 提交失败:'
            Write-Output $newHead
            exit 1
        }

        if ($oldHead) { git update-ref HEAD $newHead $oldHead }
        else { git update-ref HEAD $newHead }
        if ($LASTEXITCODE -ne 0) { throw 'git update-ref 失败' }
    }
    finally {
        $env:GIT_INDEX_FILE = $oldIndex
        Remove-Item -LiteralPath $tempIndex -Force -ErrorAction SilentlyContinue
    }

    $hash = (git rev-parse --short HEAD).Trim()
    Write-Output "[git-management] 快照完成: $hash  ($($changes.Count) 项改动)"
    Write-Output "[git-management] 提交信息: $Message"
    Write-Output "[git-management] 已使用临时 index；真实 index 文件未被改写。"
    Write-Output "[git-management] 仅本地提交，未推送远程。"
}
finally {
    Pop-Location
}

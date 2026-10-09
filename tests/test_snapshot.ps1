#!/usr/bin/env pwsh
#requires -Version 7.0
[CmdletBinding()]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$failed = 0
$root = Join-Path ([IO.Path]::GetTempPath()) ('git-snapshot-test-' + (Get-Date -Format 'MMdd-HHmmss'))
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Assert-Equal($actual, $expected, [string]$name) {
    if ($actual -eq $expected) {
        Write-Host ("  PASS  " + $name) -ForegroundColor Green
    }
    else {
        Write-Host ("  FAIL  " + $name + " (expected " + $expected + ", got " + $actual + ")") -ForegroundColor Red
        $script:failed++
    }
}

function New-TestRepo([string]$name) {
    $dir = Join-Path $root $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    git -C $dir init -q
    git -C $dir config user.name Test
    git -C $dir config user.email test@example.com
    Set-Content -LiteralPath (Join-Path $dir 'a.txt') -Value 'base' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $dir 'b.txt') -Value 'base' -Encoding ascii
    git -C $dir add a.txt b.txt
    git -C $dir commit -qm init
    Set-Content -LiteralPath (Join-Path $dir 'a.txt') -Value 'staged' -Encoding ascii
    git -C $dir add a.txt
    Set-Content -LiteralPath (Join-Path $dir 'b.txt') -Value 'unstaged' -Encoding ascii
    return $dir
}

try {
    Write-Host '== snapshot.ps1 =='
    $repo = New-TestRepo 'manual'
    $indexBefore = (Get-FileHash -LiteralPath (Join-Path $repo '.git/index') -Algorithm SHA256).Hash
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\scripts\snapshot.ps1') -Path $repo | Out-Null
    Assert-Equal $LASTEXITCODE 0 'snapshot exits 0'
    $indexAfter = (Get-FileHash -LiteralPath (Join-Path $repo '.git/index') -Algorithm SHA256).Hash
    Assert-Equal $indexAfter $indexBefore 'real index file unchanged'
    $files = @(git -C $repo show --name-only --format= HEAD)
    Assert-Equal (($files -contains 'a.txt') -and ($files -contains 'b.txt')) $true 'snapshot contains staged and unstaged changes'
    $head1 = (git -C $repo rev-parse HEAD).Trim()
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\scripts\snapshot.ps1') -Path $repo | Out-Null
    $head2 = (git -C $repo rev-parse HEAD).Trim()
    Assert-Equal $head2 $head1 'no-op snapshot does not create an empty commit'

    Write-Host '== autosnapshot.ps1 =='
    $repo = New-TestRepo 'auto'
    $indexBefore = (Get-FileHash -LiteralPath (Join-Path $repo '.git/index') -Algorithm SHA256).Hash
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '..\scripts\autosnapshot.ps1') -Path $repo -IntervalSeconds 0 | Out-Null
    Assert-Equal $LASTEXITCODE 0 'autosnapshot exits 0'
    $indexAfter = (Get-FileHash -LiteralPath (Join-Path $repo '.git/index') -Algorithm SHA256).Hash
    Assert-Equal $indexAfter $indexBefore 'autosnapshot leaves real index file unchanged'
    $files = @(git -C $repo show --name-only --format= HEAD)
    Assert-Equal (($files -contains 'a.txt') -and ($files -contains 'b.txt')) $true 'autosnapshot contains staged and unstaged changes'
}
finally {
    if (-not $Keep) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failed -gt 0) {
    Write-Host ("RESULT: FAIL (" + $failed + ")") -ForegroundColor Red
    exit 1
}
Write-Host 'RESULT: OK' -ForegroundColor Green
exit 0

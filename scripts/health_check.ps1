#requires -Version 7.0
<#
health_check.ps1 —— 一键体检（把"原先要人工逐条敲的检查"合并成一条）

★ 为什么有这个脚本
  用户 2026-09-30 明确要求："这些检查命令以后自动运行，别每次让我开口。"
  → 把下面 7 项检查合并成一条命令，并挂到两条**自动链路**上（不需要用户说话）：
     ① 每日备份尾部：run_backup.ps1 末尾调用 `-WriteLog`
        → 报告写入 <UploadRoot>\logs\health_last.txt（每天至少 1 次，13:52 兜底任务）
     ② 每次新会话：git-management 的 sessionstart.ps1 自动注入上一次结论摘要
  → 用户不开口也能看到结论；要看明细时手工跑本脚本。

检查项
  1 automation      CodeBuddy 定时任务 skill-github / ai-memory-sync 是否存在且 ACTIVE
  2 scheduled-task  Windows 计划任务 Wake-1345 / App-1346 / Backup-1352 是否 Ready
  3 three-systems   三套体系：本地 skills 与镜像落差数、skill 自建仓库未提交数
  4 memory          memory\ai-memory.md 条目数 + md/json 一致性（sync_memory.py --check）
  5 remote-sha      远端 SHA 验收：live ls-remote 与本地 HEAD 是否一致（-Quick 跳过）
  6 market-skills   state.json 里 source=market 的 skill 是否都在本机
  7 upload-gate     上传门禁：git config --global core.hooksPath 是否启用

用法
  pwsh -NoProfile -File health_check.ps1                 # 全量（联网验 SHA）
  pwsh -NoProfile -File health_check.ps1 -Quick          # 不联网（会话启动用）
  pwsh -NoProfile -File health_check.ps1 -SummaryOnly    # 只输出一行结论（供 hook 捕获）
  pwsh -NoProfile -File health_check.ps1 -WriteLog       # 另写 <UploadRoot>\logs\health_last.txt

退出码：0 = 全绿 ｜ 2 = 有警告 ｜ 1 = 有失败
#>
[CmdletBinding()]
param(
    [switch]$Quick,
    [switch]$SummaryOnly,
    [switch]$WriteLog,
    [int]$RemoteTimeoutSec = 15,
    [string]$SkillsRoot = (Join-Path $HOME '.codebuddy\skills'),
    [string]$UploadRoot = (Join-Path $HOME 'CodeBuddy\skills-auto-upload')
)

$ErrorActionPreference = 'Continue'
if ($PSStyle) { $PSStyle.OutputRendering = 'PlainText' }

# ══ 结果收集 ═══════════════════════════════════════════════════════════════
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Lines = New-Object System.Collections.Generic.List[string]

function Add-Result {
    param([string]$Name, [string]$Level, [string]$Short, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Name = $Name; Level = $Level; Short = $Short; Detail = $Detail })
}

# Say：既写报告文本、又打屏。SummaryOnly 模式下**只收集不打印**，
#   保证 stdout 上只剩最后那一行结论（sessionstart hook 会捕获 stdout，必须干净）。
function Say {
    param([string]$Text = '', [string]$Color = 'Gray')
    $script:Lines.Add($Text)
    if (-not $SummaryOnly) {
        if ($Color -eq 'Gray') { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
    }
}

# ══ 工具 ═══════════════════════════════════════════════════════════════════
$gitExe = 'git'
try { $g = Get-Command git -ErrorAction SilentlyContinue; if ($g) { $gitExe = $g.Source } } catch { }

$pwshExe = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwshExe)) { $pwshExe = 'pwsh' }

# python：优先 PATH；PATH 上没有时（hook / 计划任务的 PATH 可能与交互会话不同）
#   退回 CodeBuddy 托管运行时与 anaconda 常见位置。
$pyExe = 'python'
try {
    $p = Get-Command python -ErrorAction SilentlyContinue
    if ($p) { $pyExe = $p.Source }
    else {
        $cands = @()
        $cands += @(Get-ChildItem -Path (Join-Path $HOME '.workbuddy\binaries\python\versions') -Filter 'python.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        $cands += 'F:\anaconda3\python.exe'   # 本机 anaconda 固定位置（Test-Path 兜底，不存在就跳过）
        foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { $pyExe = $c; break } }
    }
}
catch { }

# 带超时地跑一个外部命令（远端 git 不通时会挂 ~21s，必须设上限）
function Invoke-Proc {
    param([string]$File, [string[]]$ArgList, [int]$TimeoutSec = 30)
    $so = [IO.Path]::GetTempFileName()
    $se = [IO.Path]::GetTempFileName()
    try {
        $quoted = @($ArgList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
        $proc = Start-Process -FilePath $File -ArgumentList $quoted -NoNewWindow -PassThru `
            -RedirectStandardOutput $so -RedirectStandardError $se -ErrorAction Stop
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ Ok = $false; Out = ''; Err = ''; Reason = "超时(>${TimeoutSec}s)" }
        }
        $o = ((Get-Content -LiteralPath $so -Raw -ErrorAction SilentlyContinue) + '').Trim()
        $e = ((Get-Content -LiteralPath $se -Raw -ErrorAction SilentlyContinue) + '').Trim()
        return [pscustomobject]@{ Ok = ($proc.ExitCode -eq 0); Out = $o; Err = $e; Reason = '' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Out = ''; Err = ''; Reason = $_.Exception.Message }
    }
    finally {
        Remove-Item -LiteralPath $so, $se -Force -ErrorAction SilentlyContinue
    }
}

$now = Get-Date
Say ''
Say ("═══════════ 自动体检  " + $now.ToString('yyyy-MM-dd HH:mm:ss') + " ═══════════") 'Cyan'
Say ''

# ══ 1. automation ══════════════════════════════════════════════════════════
Say '【1】automation（CodeBuddy 定时任务所在 SQLite）'
$wantAuto = @(
    [pscustomobject]@{ Id = 'skill-github';   Want = 'BYHOUR=14;BYMINUTE=30' },
    [pscustomobject]@{ Id = 'ai-memory-sync'; Want = 'BYHOUR=13;BYMINUTE=45' }
)
$dbPath = Join-Path $env:APPDATA 'CodeBuddy CN\automations\automations.db'
if (-not (Test-Path -LiteralPath $dbPath)) {
    Add-Result 'automation' 'WARN' '未找到 automations.db'
    Say ('   ⚠ 未找到 ' + $dbPath) 'Yellow'
}
else {
    $rows = @{}
    $code = "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);[print(r[0]+chr(124)+r[1]+chr(124)+r[2]) for r in c.execute('select id,status,rrule from automations')]"
    $rr = Invoke-Proc -File $pyExe -ArgList @('-c', $code, $dbPath) -TimeoutSec 30
    if (-not $rr.Ok -or [string]::IsNullOrWhiteSpace($rr.Out)) {
        Add-Result 'automation' 'WARN' '读不到（python/sqlite 不可用）'
        Say ('   ⚠ 读取失败：' + $(if ($rr.Reason) { $rr.Reason } else { $rr.Err })) 'Yellow'
    }
    else {
        foreach ($ln in ($rr.Out -split "`r?`n")) {
            if ([string]::IsNullOrWhiteSpace($ln)) { continue }
            $f = $ln.Split('|')
            if ($f.Count -ge 3) { $rows[$f[0].Trim()] = [pscustomobject]@{ Status = $f[1].Trim(); Rrule = $f[2].Trim() } }
        }
        $bad = @()
        foreach ($w in $wantAuto) {
            if (-not $rows.ContainsKey($w.Id)) {
                $bad += ($w.Id + '(缺失)')
                Say ('   ✗ ' + $w.Id.PadRight(16) + ' 不存在 —— 需按 restore-extras\automations.md 重建') 'Red'
            }
            elseif ($rows[$w.Id].Status -ne 'ACTIVE') {
                $bad += ($w.Id + '(' + $rows[$w.Id].Status + ')')
                Say ('   ✗ ' + $w.Id.PadRight(16) + ' 状态=' + $rows[$w.Id].Status + '（应为 ACTIVE）') 'Red'
            }
            else {
                $hit = (($rows[$w.Id].Rrule -replace '\s', '') -match [regex]::Escape($w.Want))
                Say ('   ✓ ' + $w.Id.PadRight(16) + ' ACTIVE  ' + $rows[$w.Id].Rrule + $(if ($hit) { '' } else { '  ⚠ 与文档定义的 rrule 不同' })) 'Green'
                if (-not $hit) { $bad += ($w.Id + '(rrule 不同)') }
            }
        }
        if ($bad.Count -eq 0) { Add-Result 'automation' 'OK' '2/2 ACTIVE' }
        else { Add-Result 'automation' 'FAIL' (($bad -join ',')) ; }
    }
}
Say ''

# ══ 2. Windows 计划任务 ════════════════════════════════════════════════════
Say '【2】Windows 计划任务'
$wantTask = @('CodeBuddy-Wake-1345', 'CodeBuddy-App-1346', 'CodeBuddy-Backup-1352')
$have = @{}
try {
    foreach ($t in @(Get-ScheduledTask -TaskName 'CodeBuddy-*' -ErrorAction Stop)) { $have[$t.TaskName] = $t.State.ToString() }
}
catch { }
$missTask = @(); $warnTask = @()
foreach ($t in $wantTask) {
    if (-not $have.ContainsKey($t)) { $missTask += $t; Say ('   ✗ ' + $t + ' 不存在 —— 用 restore-extras\windows-task.ps1 重建') 'Red' }
    elseif ($have[$t] -ne 'Ready') { $warnTask += ($t + '(' + $have[$t] + ')'); Say ('   ⚠ ' + $t + ' 状态=' + $have[$t]) 'Yellow' }
    else { Say ('   ✓ ' + $t + ' Ready') 'Green' }
}
if ($missTask.Count -gt 0) { Add-Result '计划任务' 'FAIL' ('缺 ' + $missTask.Count + ' 个') }
elseif ($warnTask.Count -gt 0) { Add-Result '计划任务' 'WARN' ((3 - $warnTask.Count).ToString() + '/3 Ready') }
else { Add-Result '计划任务' 'OK' '3/3 Ready' }
Say ''

# ══ 3. 三套体系（复用 check_sync_status.ps1，避免两套判定逻辑）═════════════
Say '【3】三套体系（本地 skills ↔ 镜像 / skill 自建仓库）'
$css = Join-Path $PSScriptRoot 'check_sync_status.ps1'
if (-not (Test-Path -LiteralPath $css)) {
    Add-Result '三套体系' 'WARN' '未找到 check_sync_status.ps1'
    Say '   ⚠ 未找到 check_sync_status.ps1' 'Yellow'
}
else {
    $raw = ''
    try { $raw = (& $pwshExe -NoProfile -ExecutionPolicy Bypass -File $css -SkillsRoot $SkillsRoot -UploadRoot $UploadRoot 2>&1 | Out-String) } catch { }
    $localN = -1; $mirrorOk = -1; $gap = -1; $lastUp = '-'
    if ($raw -match '本地共 (\d+) 个 skill') { $localN = [int]$Matches[1] }
    if ($raw -match '与镜像一致 (\d+) 个') { $mirrorOk = [int]$Matches[1] }
    if ($raw -match '有落差 (\d+) 个') { $gap = [int]$Matches[1] }
    if ($raw -match '上次上传 : ([^\r\n]+)') { $lastUp = $Matches[1].Trim() }
    $uncommit = 0
    foreach ($m in [regex]::Matches($raw, '未提交 : (\d+) 个')) { $uncommit += [int]$m.Groups[1].Value }

    if ($gap -lt 0) {
        Add-Result '三套体系' 'WARN' '输出无法解析'
        Say '   ⚠ 未能解析 check_sync_status 输出' 'Yellow'
    }
    else {
        $lv = 'OK'
        if ($gap -gt 0) { $lv = 'WARN' }
        if ($uncommit -gt 0) { $lv = 'WARN' }
        Say ('   本地 ' + $localN + ' 个 skill ｜ 与镜像一致 ' + $mirrorOk + ' ｜ 落差 ' + $gap + ' ｜ 自建仓库未提交 ' + $uncommit) $(if ($lv -eq 'OK') { 'Green' } else { 'Yellow' })
        Say ('   上次上传：' + $lastUp)
        Add-Result '三套体系' $lv ('落差' + $gap + '/未提交' + $uncommit)
    }
}
Say ''

# ══ 4. memory ══════════════════════════════════════════════════════════════
Say '【4】memory（记忆备份）'
$mdPath = Join-Path $UploadRoot 'memory\ai-memory.md'
$smPath = Join-Path $UploadRoot 'memory\sync_memory.py'
if (-not (Test-Path -LiteralPath $mdPath)) {
    Add-Result '记忆' 'WARN' 'ai-memory.md 不存在'
    Say ('   ⚠ 未找到 ' + $mdPath) 'Yellow'
}
else {
    $cnt = @(Select-String -LiteralPath $mdPath -Pattern '^## \d+\.').Count
    $chkOut = ''
    if (Test-Path -LiteralPath $smPath) {
        $pr = Invoke-Proc -File $pyExe -ArgList @($smPath, '--check') -TimeoutSec 30
        $chkOut = $pr.Out
    }
    $jsonOk = ($chkOut -match 'CHECK OK')
    if ($cnt -gt 0 -and $jsonOk) {
        Add-Result '记忆' 'OK' ($cnt.ToString() + ' 条 md/json 一致')
        Say ('   ✓ ' + $cnt + ' 条 ｜ sync_memory.py --check = CHECK OK') 'Green'
    }
    elseif ($cnt -gt 0) {
        Add-Result '记忆' 'WARN' ($cnt.ToString() + ' 条 · json 待更新')
        Say ('   ⚠ ' + $cnt + ' 条，但 md/json 校验未通过（跑 python memory\sync_memory.py 重新生成）') 'Yellow'
    }
    else {
        Add-Result '记忆' 'WARN' '读不到条目'
        Say '   ⚠ 没读到 `## N. 标题` 形式的条目' 'Yellow'
    }
}
Say ''

# ══ 5. 远端 SHA（live ls-remote vs 本地 HEAD）══════════════════════════════
Say '【5】远端 SHA（live ls-remote 验收）'
if ($Quick) {
    Add-Result '远端SHA' 'INFO' '已跳过(-Quick)'
    Say '   · 已跳过（-Quick：不联网）' 'DarkGray'
}
else {
    $repos = @(
        [pscustomobject]@{ Name = 'codebuddy-skills';          Path = (Join-Path $UploadRoot 'repo');                       Main = $true },
        [pscustomobject]@{ Name = 'git-autosnapshot-codebuddy'; Path = (Join-Path $SkillsRoot 'git-management');               Main = $false },
        [pscustomobject]@{ Name = 'DSP-auto-debug';            Path = (Join-Path $SkillsRoot 'ti-c2000-ccs-auto');           Main = $false }
    )
    $mismatch = @(); $unreach = @(); $checked = 0
    foreach ($rp in $repos) {
        if (-not (Test-Path -LiteralPath (Join-Path $rp.Path '.git'))) {
            $unreach += ($rp.Name + '(无仓库)')
            Say ('   ⚠ ' + $rp.Name + '：没有 .git，跳过') 'Yellow'
            continue
        }
        $lo = ''
        try { $lo = (& $gitExe -C $rp.Path rev-parse HEAD 2>$null | Out-String).Trim() } catch { }
        $rr = Invoke-Proc -File $gitExe -ArgList @('-C', $rp.Path, 'ls-remote', 'origin', 'refs/heads/main') -TimeoutSec $RemoteTimeoutSec
        $rm = ''
        if ($rr.Ok -and $rr.Out) {
            $first = ($rr.Out -split "`n")[0]
            $rm = ($first -split "`t")[0].Trim()
        }
        $loS = if ($lo.Length -ge 10) { $lo.Substring(0, 10) } else { $lo }
        $rmS = if ($rm.Length -ge 10) { $rm.Substring(0, 10) } else { $rm }
        if ($rr.Ok -and $rm -and $lo -and ($rm -eq $lo)) {
            $checked++
            Say ('   ✓ ' + $rp.Name.PadRight(28) + $loS + ' == 远端') 'Green'
        }
        elseif (-not $rr.Ok) {
            $unreach += ($rp.Name + '(' + $(if ($rr.Reason) { $rr.Reason } else { '读不到远端' }) + ')')
            Say ('   ⚠ ' + $rp.Name.PadRight(28) + '无法读远端：' + $(if ($rr.Reason) { $rr.Reason } else { '未知' })) 'Yellow'
        }
        else {
            $mismatch += $rp.Name
            Say ('   ✗ ' + $rp.Name.PadRight(28) + 'local=' + $loS + ' remote=' + $rmS + ' —— 未推送/不一致') 'Red'
        }
    }
    # 主仓库额外确认 memory 已提交（工作区 memory/ 无未提交改动）
    $memDirty = 0
    try {
        $repoDir = Join-Path $UploadRoot 'repo'
        if (Test-Path -LiteralPath (Join-Path $repoDir '.git')) {
            $memDirty = @(git -C $repoDir status --porcelain -- memory 2>$null | Where-Object { $_ -match '\S' }).Count
            if ($memDirty -eq 0) { Say '   ✓ memory/ 工作区干净（无未提交的记忆改动）' 'Green' }
            else { Say ('   ⚠ memory/ 有 ' + $memDirty + ' 处未提交改动') 'Yellow' }
        }
    }
    catch { }

    if ($mismatch.Count -gt 0) { Add-Result '远端SHA' 'FAIL' ($mismatch -join ',') }
    elseif ($unreach.Count -gt 0) { Add-Result '远端SHA' 'WARN' ($unreach -join ',') }
    else { Add-Result '远端SHA' 'OK' ($checked.ToString() + '/' + $repos.Count + ' 一致') }
}
Say ''

# ══ 6. 市场 skill ══════════════════════════════════════════════════════════
Say '【6】市场 skill（source=market）'
$stPath = Join-Path $UploadRoot 'state.json'
if (-not (Test-Path -LiteralPath $stPath)) {
    Add-Result '市场skill' 'WARN' '缺 state.json'
    Say '   ⚠ 未找到 state.json（无法得知市场 skill 清单）' 'Yellow'
}
else {
    try {
        $stj = Get-Content -LiteralPath $stPath -Raw -Encoding utf8 | ConvertFrom-Json
        $market = @()
        foreach ($prop in $stj.baseline.PSObject.Properties) { if ($prop.Value.source -eq 'market') { $market += $prop.Name } }
        $missing = @($market | Where-Object { -not (Test-Path -LiteralPath (Join-Path $SkillsRoot $_)) })
        if ($market.Count -eq 0) {
            Add-Result '市场skill' 'WARN' 'state.json 里没有 market 条目'
            Say '   ⚠ state.json 里没有 source=market 的条目' 'Yellow'
        }
        elseif ($missing.Count -eq 0) {
            Add-Result '市场skill' 'OK' ($market.Count.ToString() + ' 个全在位')
            Say ('   ✓ ' + $market.Count + '/' + $market.Count + ' 在位（不随账号走；若市场显示未订阅，需要时按名字重装）') 'Green'
        }
        else {
            Add-Result '市场skill' 'WARN' ('缺 ' + $missing.Count + ' 个')
            Say ('   ⚠ 缺失 ' + $missing.Count + ' 个：' + ($missing -join ', ') + '（在新账号的市场按名字重装）') 'Yellow'
        }
    }
    catch {
        Add-Result '市场skill' 'WARN' '解析 state.json 失败'
        Say ('   ⚠ 解析失败：' + $_.Exception.Message) 'Yellow'
    }
}
Say ''

# ══ 7. 上传门禁 ════════════════════════════════════════════════════════════
Say '【7】上传门禁（可迁移性硬约束）'
$hooksPath = ''
try { $hooksPath = (& $gitExe config --global --get core.hooksPath 2>$null | Out-String).Trim() } catch { }
if ($hooksPath) {
    $gateOk = Test-Path -LiteralPath (Join-Path $hooksPath 'pre-push')
    if ($gateOk) {
        Add-Result '门禁' 'OK' '已启用'
        Say ('   ✓ core.hooksPath = ' + $hooksPath + '（pre-push 存在）') 'Green'
    }
    else {
        Add-Result '门禁' 'WARN' 'hooksPath 已设但无 pre-push'
        Say ('   ⚠ core.hooksPath = ' + $hooksPath + '，但里面没有 pre-push（跑 install_gate.ps1 -Global 修复）') 'Yellow'
    }
}
else {
    Add-Result '门禁' 'WARN' '未启用'
    Say '   ⚠ 未启用（上传前的可迁移性检查不会生效）—— 跑 install_gate.ps1 -Global' 'Yellow'
}
Say ''

# ══ 结论 ═══════════════════════════════════════════════════════════════════
$failN = @($script:Results | Where-Object { $_.Level -eq 'FAIL' }).Count
$warnN = @($script:Results | Where-Object { $_.Level -eq 'WARN' }).Count
$verdict = 'OK'
if ($failN -gt 0) { $verdict = 'FAIL' }
elseif ($warnN -gt 0) { $verdict = 'WARN' }

$parts = @($script:Results | Where-Object { $_.Level -ne 'INFO' } | ForEach-Object { $_.Name + ' ' + $_.Short })
$summary = '体检 ' + $now.ToString('yyyy-MM-dd HH:mm') + '：' + $verdict + ' ｜ ' + ($parts -join ' · ')

Say '────────────────────────────────────────────────'
if ($verdict -eq 'OK') { Say ('结论：OK（0 失败 / 0 警告）') 'Green' }
elseif ($verdict -eq 'WARN') { Say ('结论：WARN（0 失败 / ' + $warnN + ' 警告）') 'Yellow' }
else { Say ('结论：FAIL（' + $failN + ' 失败 / ' + $warnN + ' 警告）') 'Red' }
Say $summary

# ══ 写日志（给 sessionstart 读；也给用户事后查）════════════════════════════
if ($WriteLog) {
    try {
        $logDir = Join-Path $UploadRoot 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $body = ($script:Lines -join "`r`n") + "`r`n`r`nSUMMARY: " + $summary + "`r`n"
        Set-Content -LiteralPath (Join-Path $logDir 'health_last.txt') -Value $body -Encoding utf8
        Add-Content -LiteralPath (Join-Path $logDir 'health_history.log') -Value ('[' + $now.ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $summary)
    }
    catch { }
}

if ($SummaryOnly) { Write-Output $summary }

if ($failN -gt 0) { exit 1 }
elseif ($warnN -gt 0) { exit 2 }
else { exit 0 }

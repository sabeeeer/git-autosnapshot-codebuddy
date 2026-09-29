# Git 自动快照 - CodeBuddy（Skill）

> 把任意工作目录登记成 Git 仓库，持续保存**可回退的本地快照**，完全不依赖远程仓库。
> 由 CodeBuddy 的 Hooks + 后台监听进程实现「打开即生效、保存即快照」。

安全铁律：**只做本地提交** —— 绝不 push 远程、绝不制造空提交、绝不修改 `git config`、
绝不擅自执行 `reset --hard` / `clean -fd` / `push --force` 等破坏性操作。

---

## 1. 功能

| 触发时机 | 机制 | 脚本 |
|---|---|---|
| 打开工程开始会话 | `SessionStart` hook：启动后台监听 + 注入上下文 | `scripts/sessionstart.ps1` |
| AI 新建/修改文件后 | `PostToolUse` hook（matcher `Write\|Edit`） | `scripts/autosnapshot.ps1` |
| **用户手动 Ctrl+S 保存** | 后台监听进程轮询（Hook 感知不到编辑器保存） | `autosnapshot.ps1 -Watch` |
| 会话结束 | `SessionEnd` hook：停止监听 | `autosnapshot.ps1 -Stop` |

引擎规则要点：

- **限流**：默认最快 60 秒一个快照（`-IntervalSeconds`，设 0 = 每次改动都提交）
- **无改动绝不提交**；单实例保护；监听进程最长 8 小时后自动退出（`-MaxHours`）
- **无 git 身份兜底**：全局/系统/仓库都没有 `user.name`/`user.email` 时，用
  `git -c ...` 以 `CodeBuddy Auto Snapshot <autosnapshot@local>` 提交（只对单条命令生效，不写任何配置）
- **构建产物防护**：工程没有 `.gitignore` 时，自动把 `Debug/`、`Release/`、`*.obj`、`*.out`、`*.map` 等
  写入 `<.git>/info/exclude`（在 `.git` 内部，不污染工程目录）
- 状态与日志放在 `.git/` 内部：`codebuddy-last-autosnapshot`、`codebuddy-autosnapshot.log`
- 安全保护：不会在盘符根目录 / 用户目录 / 系统目录里自动 `git init`
- 单个工程要关闭：放一个空文件 `<工程>/.codebuddy/autosnapshot.off`

## 2. 目录结构

```
SKILL.md                      # 主文件：触发词→动作、标准流程、安全回退、边界与陷阱
README.md                     # 本文件
scripts/
  snapshot.ps1                # 一键快照（含"无改动不提交"保护）
  autosnapshot.ps1            # 自动快照引擎（hook / -Watch 监听 / -Stop 停止）
  sessionstart.ps1            # 会话启动：拉起监听 + 输出上下文
  session-context.txt         # 注入给 AI 的上下文（UTF-8，含中文）
```

## 3. 安装

**第一步**：把本文件夹放到 skills 目录

```
Windows:   C:\Users\<你的用户名>\.codebuddy\skills\git-management\
Linux/mac: ~/.codebuddy/skills/git-management/
```

**第二步**：在**用户级** `~/.codebuddy/settings.json` 里配置 hooks（所有工程自动生效）：

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup",
        "hooks": [ { "type": "command",
                     "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"<skill目录>/scripts/sessionstart.ps1\"",
                     "timeout": 30 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit|write_to_file|replace_in_file",
        "hooks": [ { "type": "command",
                     "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"<skill目录>/scripts/autosnapshot.ps1\"",
                     "timeout": 30 } ] }
    ],
    "SessionEnd": [
      { "matcher": "*",
        "hooks": [ { "type": "command",
                     "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"<skill目录>/scripts/autosnapshot.ps1\" -Stop",
                     "timeout": 20 } ] }
    ]
  }
}
```

把 `<skill目录>` 换成实际路径（如 `C:/Users/you/.codebuddy/skills/git-management`）。改完 hooks 要重开会话/重载窗口才生效。

## 4. 手动用法

```powershell
# 对指定目录做一次快照（默认提交信息 snapshot: yyyy-MM-dd HH:mm）
pwsh -ExecutionPolicy Bypass -File "<skill>\scripts\snapshot.ps1" -Path "<工程目录>"

# 定时快照命名规范
pwsh -ExecutionPolicy Bypass -File "<skill>\scripts\snapshot.ps1" -Path "<工程>" -Message "auto-snapshot 2026-09-17"

# 手动启动/停止监听（前台可见，便于观察）
pwsh -ExecutionPolicy Bypass -File "<skill>\scripts\autosnapshot.ps1" -Watch -Echo -Path "<工程>"
pwsh -ExecutionPolicy Bypass -File "<skill>\scripts\autosnapshot.ps1" -Stop  -Echo -Path "<工程>"

# 查看快照历史 / 日志
git -C "<工程>" log --oneline -20
Get-Content "<工程>\.git\codebuddy-autosnapshot.log" -Tail 20
```

触发词（对 AI 说）：`git快照`、`记录当前文件夹`、`把当前工程登记一下`、`存个档`、`看看有哪些改动`、`回退到上次快照`…

## 5. 安全回退（先备份再操作）

```bash
git log --oneline -20                 # 先看历史
git reset --soft HEAD~1               # 撤销最近一次提交，改动保留在工作区
git restore --source=<hash> -- <file> # 把某文件恢复成某次快照的版本（先备份！）
git reflog                            # 误删提交时找回
```

**必须用户明确要求并二次确认**才可执行：`git reset --hard`、`git clean -fd`、`git push --force`、`rebase`、`filter-branch`。

## 6. 边界（务必知道）

- 快照只保护**目录内已有的改动历史**：整个文件夹被删除或磁盘损坏时，本地 `.git` 一起丢失，无法恢复 ——
  需要异地备份或推到远程才真正安全。
- `git add -A` 会把 `Debug/`、`*.obj`、`*.out`、`*.map` 等构建产物纳入（除非有 `.gitignore` 或被 `info/exclude` 排除）。
- 提交失败常见原因：未配置 `user.name` / `user.email`。本 skill **不会替用户改 git config**，请自行执行：
  ```bash
  git config --global user.name  "你的名字"
  git config --global user.email "你的邮箱"
  ```

## 7. 编码约定（改脚本前必读）

引擎要求：**PowerShell 7.0+（pwsh）**——三个脚本首行都是 `#requires -Version 7.0`，hooks 用 pwsh.exe 绝对路径调用，不会退回 Windows PowerShell 5.1。

`snapshot.ps1` 为 **UTF-8 with BOM**（含中文输出）；
`autosnapshot.ps1` / `sessionstart.ps1` 保持**纯 ASCII**（历史约定：兼容任意引擎、避免编码坑），
中文提示放在 `session-context.txt`（按 UTF-8 显式读取）。修改脚本时请保持各自编码。

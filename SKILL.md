---
name: git-management
description: >
  本地 Git 版本快照与仓库管理（不依赖远程仓库）。当用户说 "git快照"、"记录当前文件夹"、"把当前工程登记一下"、
  "使用快照任务"、"存个档"、"版本快照"、"看看有哪些改动"、"有没有未提交的"、"回退到上次快照"、"撤销这次提交"、
  "查看快照历史" 等，或需要对某个目录做本地版本登记、改动检查、历史查看、安全回退时触发。核心流程：无 .git 时
  git init → git status 检查 → 有改动才 git add -A 并提交 "snapshot: YYYY-MM-DD HH:MM"。安全铁律：只做本地操作，
  绝不推送远程、绝不创建空提交、绝不修改 git config、绝不擅自执行破坏性操作（reset --hard / clean -fd / push --force）。
tags: [git, 快照, snapshot, 版本管理, 本地仓库, commit, 回退, 版本控制]
---

# Git 本地版本快照与管理

把任意工作目录登记成 Git 仓库，并保存**可回退的本地快照**，完全不依赖远程仓库。

## 触发词 → 动作对照

| 用户说法 | 应执行的动作 |
|---|---|
| "git快照" / "记录当前文件夹" / "把当前工程登记一下" / "使用快照任务" / "存个档" | 执行「标准快照流程」 |
| "看看有哪些改动" / "有没有未提交的" | 只运行 `git status`，**不修改任何东西** |
| "回退到上次快照" / "撤销这次快照" | 执行「安全回退」，先备份再操作 |
| "每天/定时自动快照" | 创建 automation（不要用本 skill 手工反复跑） |

## 标准快照流程

1. **确认目标目录**（默认当前工作目录）。目录不存在 → 直接报错退出，不要猜测路径。
2. **没有 `.git` 就先初始化**：
   ```bash
   git init
   ```
3. **检查改动**（判断"有无改动"的唯一依据，必做）：
   ```bash
   git status --porcelain
   ```
4. **输出为空 → 什么都不做**，明确回报"无改动，跳过提交"。
   **严禁 `git commit --allow-empty`，严禁制造空提交。**
5. **有改动才提交**：
   ```bash
   git add -A
   git commit -m "snapshot: YYYY-MM-DD HH:MM"
   ```
   - 手工/交互快照用：`snapshot: 2026-09-16 21:30`
   - 定时/自动化快照用：`auto-snapshot 2026-09-16`
6. **回报结果**：commit 短哈希 + 改动项数 + 提交信息。**绝不 push。**

## 一键脚本

`scripts/snapshot.ps1` 已封装上述全部逻辑（含"无改动不提交"保护）：

```powershell
# 对指定目录快照（默认提交信息 snapshot: yyyy-MM-dd HH:mm）
powershell -ExecutionPolicy Bypass -File "<skill目录>\scripts\snapshot.ps1" -Path "<你的工程目录>"

# 自定义提交信息（定时快照命名规范）
powershell -ExecutionPolicy Bypass -File "<skill目录>\scripts\snapshot.ps1" -Message "auto-snapshot 2026-09-16"
```

脚本行为：无 `.git` → `git init`；无改动 → 打印"跳过"并 `exit 0`；有改动 → `add -A` + `commit`。
脚本**不会** push、不会改 git config、不会创建空提交。

## 自动快照（Hook + 后台监听）

Skill 自身无法监听文件事件，"打开即生效 / 保存即快照"由 CodeBuddy **Hooks** + 一个后台监听进程实现：

| 触发时机 | 机制 | 脚本 |
|---|---|---|
| 打开工程开始会话 | `SessionStart` hook：启动监听进程 + 注入"本工程启用 git-management"上下文 | `scripts/sessionstart.ps1` |
| AI 新建/修改文件后 | `PostToolUse` hook（matcher `Write\|Edit`） | `scripts/autosnapshot.ps1` |
| **用户手动 Ctrl+S 保存** | 后台监听进程轮询（Hook 感知不到编辑器保存，只能这样覆盖） | `autosnapshot.ps1 -Watch` |
| 会话结束 | `SessionEnd` hook：停止监听进程 | `autosnapshot.ps1 -Stop` |

Hook 配置写在**用户级** `~/.codebuddy/settings.json`（Windows 即 `C:\Users\<用户名>\.codebuddy\settings.json`），
**所有工程**自动生效，不必在每个工程里重复配置。

- 目标仓库按 `$CODEBUDDY_PROJECT_DIR` → `$CLAUDE_PROJECT_DIR` → 当前目录 的顺序确定
- **单个工程要关闭**：在该工程放一个空文件 `<工程>/.codebuddy/autosnapshot.off`
- 安全保护：不会在盘符根目录 / 用户目录 / 系统目录里自动 `git init`
- 跟踪文件超过 10000 个的大仓库只保留 PostToolUse 触发，不做轮询监听
- hooks 配置改动后需要重开会话 / 重载窗口才生效

自动快照引擎 `scripts/autosnapshot.ps1` 的规则：

- **限流**：默认最快 60 秒产生一个快照（`-IntervalSeconds`，设 `0` = 每次改动都提交）
- 无改动绝不提交；只做本地 commit，**绝不 push、绝不改 git config**
- 状态与日志放在 `.git/` 内部，不会被提交：`codebuddy-last-autosnapshot`、`codebuddy-autosnapshot.log`
- **无 git 身份兜底**：若全局/系统/仓库都没有配置 `user.name` / `user.email`，则用 `git -c ...` 以
  `CodeBuddy Auto Snapshot <autosnapshot@local>` 身份提交 —— 只对单条命令生效，**不写入任何配置文件**；
  配置了真实身份则自动使用真实身份
- **构建产物防护**：工程没有 `.gitignore` 时，自动把 `Debug/`、`Release/`、`*.obj`、`*.out`、`*.map` 等规则
  写入 `<.git>/info/exclude`（位于 `.git` 内部，不污染工程目录）；已有 `.gitignore` 的工程不干预
- 单实例保护；监听进程最长运行 8 小时后自动退出（`-MaxHours`）

手动控制与排查：

```powershell
# 启动监听（前台可见，便于观察；-Path 可省略，默认按 $CODEBUDDY_PROJECT_DIR / 当前目录定位）
powershell -ExecutionPolicy Bypass -File "<skill目录>\scripts\autosnapshot.ps1" -Watch -Echo -Path "<工程目录>"

# 停止监听（-Path 同样可省略）
powershell -ExecutionPolicy Bypass -File "<skill目录>\scripts\autosnapshot.ps1" -Stop -Echo -Path "<工程目录>"

# 查看自动快照日志 / 历史
Get-Content "<工程目录>\.git\codebuddy-autosnapshot.log" -Tail 20
git -C "<工程目录>" log --oneline -20
```

> 脚本文件编码：`snapshot.ps1` 为 UTF-8 with BOM（含中文输出）；`autosnapshot.ps1` / `sessionstart.ps1` 为纯 ASCII（避免 PowerShell 5.1 按 ANSI 读取中文导致语法错误），中文提示放在 `session-context.txt`（按 UTF-8 显式读取）。修改脚本时请保持各自编码。

## 安全回退（先备份，再操作）

```bash
git log --oneline -20            # 先看清楚历史
git show <hash> --stat           # 看某次快照改了什么

# 推荐：撤销最近一次提交，但文件改动全部保留在工作区
git reset --soft HEAD~1

# 推荐：把某个文件恢复到某次快照的版本（先复制一份备份！）
git restore --source=<hash> -- <file>

# 误删/丢失提交时找回
git reflog
git checkout -b rescue <sha-from-reflog>
```

**必须用户明确要求并二次确认后才可执行**（默认一律不做）：

- `git reset --hard` / `git clean -fd`（会永久丢弃未提交改动）
- `git push --force` / `git rebase` 改写已共享历史
- `git filter-branch` / `git gc --prune=now`

## 常用查询

```bash
git status -sb                   # 分支 + 精简改动
git log --oneline --graph -20    # 快照历史
git diff --stat                  # 未暂存改动统计
git show <hash>                  # 某次快照详情
```

## 边界与陷阱（重要）

- **快照只能保护"目录内已有的改动历史"**；若整个文件夹被删除或磁盘损坏，本地 `.git` 一起没了就无法恢复 —— 需要异地备份或推到远程才安全。务必向用户说明这一点。
- **不做远程操作**：除非用户明确要求并确认，本 skill 只做本地提交，`git push` 一律不碰。
- **构建产物/大文件**：`git add -A` 会把 `Debug/`、`*.obj`、`*.out`、`*.map` 等一起纳入。若用户在意仓库体积，建议写入 `.gitignore` 或改用针对性 `git add`。
- **自动化自身目录**（如 `.codebuddy/`）：会被 `-A` 纳入快照。如不希望，就在 `.gitignore` 里排除。
- **提交失败常见原因**：未配置 `user.name` / `user.email`。**不要替用户改 git config**，把修复命令告诉用户让其自行执行：
  ```bash
  git config --global user.name  "你的名字"
  git config --global user.email "你的邮箱"
  ```
- Windows 中文路径/文件名正常可用；`git status` 里显示 `\344\275\240` 这类转义只是显示问题，不影响内容。
- 提交前若发现疑似密钥、密码、超大二进制文件，先停下来提醒用户确认。

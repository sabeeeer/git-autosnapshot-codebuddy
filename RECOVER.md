# 恢复指南（本仓库）

本仓库是独立 skill 仓库。**完整恢复流程**见主仓库：

- 主仓库 **`sabeeeer/codebuddy-skills`**（skill + AI 记忆 + 恢复脚本一体）
- 恢复入口：主仓库根 **`RECOVER.md`**
- 一键恢复：在主仓库副本里执行 `pwsh -NoProfile -File ./restore.ps1 -Apply`

## 本仓库单独恢复

```bash
git clone git@github.com:<owner>/<repo>.git
# 复制到 skill 目录（CodeBuddy）
#   Windows:  xcopy /E /I /Y <repo> "%USERPROFILE%\.codebuddy\skills\git-management"
#   bash:     cp -r <repo> ~/.codebuddy/skills/git-management
```

## 依赖

- **PowerShell 7**（所有 `.ps1` 脚本；Windows PowerShell 5.1 会因编码/`$PSStyle`/`Select-String` 行为差异出错）
- **git**

## 关键脚本

| 脚本 | 用途 |
|---|---|
| `scripts/snapshot.ps1` | 对指定目录做一次本地快照（无改动不提交） |
| `scripts/autosnapshot.ps1` | 自动快照后台监听（被 CodeBuddy hooks 调用） |
| `scripts/check_sync_status.ps1` | **同步状态体检** —— 一次查全三套上传/备份体系 |
| `scripts/portability_gate.ps1` | **可迁移性门禁** —— 检查内容是否满足"登录 GitHub 即可迁移" |
| `scripts/install_gate.ps1` | 把门禁装到仓库的 `pre-push` hook（推送前自动检查） |

## 可迁移性

本仓库遵守主仓库 `PORTABILITY.md` 的十条规范（内容平台中立、路径不硬编码、凭据不入库、关键目录 ASCII）。

安装门禁（推送前自动检查，不通过则拒绝推送）：

```powershell
pwsh -NoProfile -File "$env:USERPROFILE/.codebuddy/skills/git-management/scripts/install_gate.ps1" -Path <本仓库>
```

应急绕过：`git push --no-verify`（建议事后补检）。

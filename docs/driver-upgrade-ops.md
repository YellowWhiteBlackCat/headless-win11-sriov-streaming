# Intel Arc 驱动升级运维（长期可复用流程）

参考机把“驱动升级”收敛为宿主端一条命令：下载校验 → 推送到 guest →
`upgrade-intel-driver.ps1` 升级并重启 → 等待 RunOnce 自愈 → 检查/修复 VDD →
确认 Sunshine 交互会话恢复 → 全量验收 → 生成带时间戳的报告。

## 一条命令

```bash
bash scripts/host/upgrade-intel-driver.sh
```

该命令做完整升级流程（默认目标：Intel Arc 32.0.101.8991，官方 2026-08-24
Game On / Non-WHQL 发布，下载地址与 SHA-256 固化在
`scripts/download-assets.sh` / `assets.sha256`）。报告写入
`logs/upgrade-intel-driver-<时间戳>.log`（gitignored，不提交）。

## 常用变体

只采集当前状态并跑验收（不下载、不推送、不改 guest）：

```bash
bash scripts/host/upgrade-intel-driver.sh --status-only
```

跳过最后的 `verify-stack.sh`：

```bash
bash scripts/host/upgrade-intel-driver.sh --skip-verify-stack
```

回滚/降级到本地安装包（例如 8974 WHQL）：

```bash
bash scripts/host/upgrade-intel-driver.sh \
  -f drivers/IntelArcDriver/gfx_win_101.8974.exe \
  -e 32.0.101.8974
```

自定义下载源（`INTEL_URL` / `INTEL_SHA` 也会被
`scripts/download-assets.sh` 使用）：

```bash
INTEL_URL=https://downloadmirror.intel.com/926884/gfx_win_101.8991.exe \
INTEL_SHA=ea230464eb1c58f98d7b379b16369033bf4eeff55af1a8a3b78026adf2bb425d \
  bash scripts/host/upgrade-intel-driver.sh
```

其他环境变量：`DOM`（默认 `win11`）、`URI`（默认 `qemu:///system`）、
`SSH_HOST`（默认 `win-dev`）、`LOG_DIR`（默认仓库 `logs/`）。

## 流程细节

1. 前置检查：VM 必须 running，SSH 可达；记录升级前驱动版本。
2. 安装包：优先用 `-f` 指定的本地文件，否则使用固定 URL 下载；总是校验
   SHA-256。
3. 推送：scp 到 guest `C:\Admin\drivers\IntelArcDriver\`，并在 guest 内
   `Get-FileHash` 复核。
4. 同步 guest 运维脚本（`upgrade-intel-driver.ps1`、`rebuild-vdd.ps1`、
   `get-driver-version.ps1`、`get-ops-state.ps1`）。
5. 执行 guest 升级：停 Sunshine → 禁用 VDD → Intel 安装器 `-s` 静默安装 →
   写 RunOnce → 重启。
6. 等待（最长 15 分钟）：驱动版本变为目标版本且升级日志出现
   “Post-reboot upgrade phase finished”。
7. VDD 完整性：期望恰好一个 `ROOT\DISPLAY\0000` 且 status=OK；若为 0 个、
   多个或 Error，自动运行 `rebuild-vdd.ps1`（pnputil 删除全部 VDD 节点后
   重装唯一一个）。
8. Sunshine：必须通过 `SunshineUser` 交互计划任务启动（从 SSH/服务会话直接
   启动会 `ERROR_ACCESS_DENIED`、显示 0 个显示器）；检查进程与
   `hevc_qsv` 编码器日志。
9. 全量验收：`scripts/verify-stack.sh`，期望 `PASS=15 FAIL=0`。

## 已知要点

- Intel 官方 8991 是 **Non-WHQL Game On**；8974 才是 WHQL。WagnardSoft 把
  8991 标成 WHQL 是错的，以官方 ReleaseNotes 为准。
- `devcon remove` 在驱动升级后可能报 “No devices were removed” 并留下重复
  `ROOT\DISPLAY\0001`，因此重建统一走 pnputil（`rebuild-vdd.ps1`）。
- 升级成功与否以验收脚本为准，不是以安装器退出码为准（Intel 安装器返回
  1000 表示需重启，属正常）。
- ViGEmBus 未安装时 Sunshine 会打一行非致命 Fatal（仅影响手柄），不影响
  画面串流。

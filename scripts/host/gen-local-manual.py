#!/usr/bin/env python3
"""Generate the local, human-readable maintenance manual for this VM.

The repository itself is public and must stay sanitized. This script is the
intended bridge: it reads the git-ignored ``secrets.local.env`` and live host
state, then writes a complete plaintext manual (with real passwords) to the
user's download directory, mode 0600.

Run on the real host:

    python3 scripts/host/gen-local-manual.py

Environment overrides:

    OUTPUT_DIR=/path/to/dir  python3 scripts/host/gen-local-manual.py
    DOM=win11 SSH_HOST=win-dev URI=qemu:///system

The script never prints secret values.
"""

from __future__ import annotations

import argparse
import base64
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SECRETS = REPO / "secrets.local.env"


def run(cmd: list[str], timeout: int = 10) -> str:
    """Run a command and return stdout, or an empty string on failure."""
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.stdout.strip()
    except Exception:
        return ""


def run_ssh(host: str, remote_cmd: str, timeout: int = 10) -> str:
    """Run a remote command through the user's ssh config.

    Uses ``-F ~/.ssh/config`` so it also works when system ssh_config.d files
    are unreadable (e.g. inside a container/sandbox). On a healthy host plain
    ``ssh`` is equivalent.
    """
    cfg = Path.home() / ".ssh" / "config"
    base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
    if cfg.exists():
        base += ["-F", str(cfg)]
    return run(base + [host, remote_cmd], timeout=timeout)


def run_ssh_ps(host: str, script: str, timeout: int = 15) -> str:
    """Run a PowerShell script through the remote cmd wrapper reliably.

    Windows OpenSSH feeds the command to cmd.exe by default, so pipes,
    braces and `$_` in a plain argument get mangled. -EncodedCommand keeps the
    script byte-for-byte intact regardless of the local shell.
    """
    encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    return run_ssh(host, f"powershell -NoProfile -EncodedCommand {encoded}", timeout=timeout)


def load_secrets(path: Path) -> dict[str, str]:
    secrets: dict[str, str] = {}
    if not path.exists():
        return secrets
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        secrets[key.strip()] = value.strip().strip('"').strip("'")
    return secrets


def download_dir() -> Path:
    xdg = run(["xdg-user-dir", "DOWNLOAD"])
    if xdg and Path(xdg).is_dir():
        return Path(xdg)
    for candidate in (Path.home() / "下载", Path.home() / "Downloads"):
        if candidate.is_dir():
            return candidate
    return Path.home()


def git_head() -> str:
    head = REPO / ".git" / "HEAD"
    try:
        ref = head.read_text(encoding="utf-8").strip()
        if ref.startswith("ref:"):
            ref = (REPO / ".git" / ref[5:].strip()).read_text(encoding="utf-8").strip()
        return ref[:12]
    except Exception:
        return "unknown"


def live_facts() -> dict[str, str]:
    facts: dict[str, str] = {}

    # Host basics
    facts["hostname"] = run(["hostname"]) or "unknown"
    facts["kernel"] = run(["uname", "-r"]) or "unknown"
    release = run(["sed", "-n", "s/^PRETTY_NAME=//p", "/etc/os-release"])
    facts["os_release"] = release.strip('"') or "unknown"
    facts["qemu"] = (run(["qemu-system-x86_64", "--version"]) or "").splitlines()[0:1]
    facts["qemu"] = facts["qemu"][0] if facts["qemu"] else "unknown"
    facts["libvirt"] = (run(["virsh", "--version"]) or "").splitlines()[0:1]
    facts["libvirt"] = facts["libvirt"][0] if facts["libvirt"] else "unknown"

    # Git state
    remote = run(["git", "-C", str(REPO), "remote", "get-url", "origin"])
    facts["git_remote"] = remote or "unknown"
    facts["git_head"] = git_head()

    # SR-IOV
    pf = os.environ.get("PF", "0000:00:02.0")
    vf_count = run(["cat", f"/sys/bus/pci/devices/{pf}/sriov_numvfs"])
    facts["vf_count"] = vf_count or "unknown"
    lspci = run(["lspci", "-nnk", "-d", "8086:"])
    facts["lspci"] = "\n".join(
        line for line in lspci.splitlines() if "00:02." in line
    ) or "unknown"
    facts["sriov_service"] = run(
        ["systemctl", "is-enabled", "b390-sriov.service"]
    ) or run(["systemctl", "is-enabled", "intel-sriov-vf.service"]) or "unknown"

    # Networks
    facts["networks"] = run(["virsh", "-c", os.environ.get("URI", "qemu:///system"), "net-list", "--all"])
    virbr0 = run(["ip", "-4", "addr", "show", "dev", "virbr0"])
    virbr1 = run(["ip", "-4", "addr", "show", "dev", "virbr1"])
    m0 = re.search(r"inet (\d+\.\d+\.\d+\.\d+/\d+)", virbr0)
    m1 = re.search(r"inet (\d+\.\d+\.\d+\.\d+/\d+)", virbr1)
    facts["virbr0"] = m0.group(1) if m0 else "unknown"
    facts["virbr1"] = m1.group(1) if m1 else "unknown"

    # Domain
    dom = os.environ.get("DOM", "win11")
    uri = os.environ.get("URI", "qemu:///system")
    facts["dom_state"] = run(["virsh", "-c", uri, "domstate", dom]) or "unknown"
    facts["dominfo"] = run(["virsh", "-c", uri, "dominfo", dom])
    facts["domiflist"] = run(["virsh", "-c", uri, "domiflist", dom])
    facts["domblklist"] = run(["virsh", "-c", uri, "domblklist", dom])
    facts["domifaddr"] = run(["virsh", "-c", uri, "domifaddr", dom, "--source", "agent"])

    # Guest (best-effort)
    ssh_host = os.environ.get("SSH_HOST", "win-dev")
    facts["guest_hostname"] = run_ssh(ssh_host, "hostname")
    guest_os = run_ssh_ps(
        ssh_host,
        "(Get-CimInstance Win32_OperatingSystem).Caption + ' build ' + (Get-CimInstance Win32_OperatingSystem).Version",
    )
    facts["guest_os"] = guest_os or "unknown"
    guest_sun = run_ssh_ps(
        ssh_host,
        "(Get-Item 'C:\\Program Files\\Sunshine\\sunshine.exe').VersionInfo.FileVersion",
    )
    facts["guest_sunshine"] = guest_sun or "unknown"
    guest_driver = run_ssh_ps(
        ssh_host,
        "(Get-CimInstance Win32_VideoController -Filter \"Name LIKE '%Arc%'\" | Select-Object -First 1).DriverVersion",
    )
    facts["guest_driver"] = guest_driver or "unknown"
    guest_vdd = run_ssh_ps(
        ssh_host,
        "(Get-PnpDevice -InstanceId 'ROOT\\DISPLAY\\0000' -ErrorAction SilentlyContinue).Status",
    )
    facts["guest_vdd"] = guest_vdd or "unknown"
    guest_sunshine_task = run_ssh_ps(
        ssh_host,
        "$i = Get-ScheduledTaskInfo -TaskName SunshineUser -ErrorAction SilentlyContinue; if ($i) { ('LastRun=' + $i.LastRunTime + ' Result=0x{0:X}' -f $i.LastTaskResult) } else { 'task missing' }",
    )
    facts["guest_sunshine_task"] = guest_sunshine_task or "unknown"
    moonlight = run(["moonlight", "-v"])
    facts["moonlight"] = moonlight.splitlines()[-1] if moonlight else "unknown"

    # OpenSSH system-config health (known pitfall in containerized/sandboxed runs)
    ssh_probe = run_ssh(ssh_host, "hostname")
    facts["ssh_healthy"] = "yes" if ssh_probe else "no"
    return facts


def render(secrets: dict[str, str], facts: dict[str, str], out: Path) -> str:
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S %Z")
    admin_pw = secrets.get("ADMIN_PASSWORD", "MISSING")
    sunshine_pw = secrets.get("SUNSHINE_WEB_PASSWORD", "MISSING")
    repo = str(REPO)
    data_root = str(REPO.parent)
    ssh_note = ""
    if facts["ssh_healthy"] != "yes":
        ssh_note = (
            "\n> ⚠️ 生成时 SSH 探测失败（常见于容器/沙箱里系统配置被映射为 nobody 属主）。\n"
            "> 真实宿主机上应能直接 `ssh win-dev`；若真机也报 `Bad owner or permissions`，\n"
            "> 检查 `/etc/ssh/ssh_config.d/` 属主并用 `sudo chown -h root:root` 修复。\n"
        )
    return f"""# WIN11 无头虚拟机 · 人工维护手册（本地机密版）

> ⚠️ 本文件包含明文密码，仅限本机使用。请勿提交到任何仓库、不要外发。
> 生成时间：{now}　|　文件权限：600
> 重新生成（一键）：`cd {repo} && python3 scripts/host/gen-local-manual.py`
> 覆盖输出目录：`OUTPUT_DIR=/path python3 scripts/host/gen-local-manual.py`
{ssh_note}
---

## 0. 一条命令确认“还活着”

```bash
virsh -c qemu:///system domstate win11          # running
virsh -c qemu:///system qemu-agent-command win11 '{{"execute":"guest-ping"}}'
ssh win-dev hostname                            # WIN11-NEW
```

---

## 1. 账号密码总表

| 用途 | 用户名 | 密码 | 备注 |
| --- | --- | --- | --- |
| Windows 本地管理员（SSH / AutoLogon） | `vmadmin` | `{admin_pw}` | SSH、桌面 AutoLogon 共用 |
| Sunshine Web UI | `sunshine` | `{sunshine_pw}` | 登录 `https://192.168.122.50:47990` |

密码副本存放位置（改密码时必须同步全部）：

1. 宿主机 `{repo}/secrets.local.env`（`ADMIN_PASSWORD` / `SUNSHINE_WEB_PASSWORD`）
2. guest `C:\\Admin\\config\\local-secrets.json`（`adminPassword` / `sunshineWebPassword` / `secondNicMac`）
3. AutoLogon 注册表 `HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon\\DefaultPassword`
4. Sunshine 哈希 `C:\\Program Files\\Sunshine\\config\\sunshine_state.json`（不要手改）

以下通道**没有**密码（不是忘了配，是设计如此）：

- VNC 救援屏：仅监听 `127.0.0.1:5900`，靠 SSH 隧道保护
- QEMU Guest Agent：virtio-serial 通道，仅宿主机可达
- Moonlight：无账号，靠首次配对证书（本机已配对客户端名 `roth`）

---

## 2. Linux 宿主机现状（本次生成时实测）

| 项目 | 值 |
| --- | --- |
| 主机名 | `{facts.get('hostname')}` |
| 系统 | `{facts.get('os_release')}` |
| 内核 | `{facts.get('kernel')}` |
| QEMU / libvirt | `{facts.get('qemu')}` / `{facts.get('libvirt')}` |
| 工作仓库 | `{repo}`（remote `{facts.get('git_remote')}`，HEAD `{facts.get('git_head')}`） |

### SR-IOV（严格 1 个 VF）

- PF：`0000:00:02.0`（Arc B390，驱动 `xe`）
- VF：`0000:00:02.1`（绑定 `xe-vfio-pci`）
- 当前 `sriov_numvfs = {facts.get('vf_count')}`
- 开机自建服务：`b390-sriov.service`（`{facts.get('sriov_service')}`）
- 预检脚本：`bash {repo}/scripts/host/check-host.sh`
- `lspci` 摘要：
```text
{facts.get('lspci')}
```

### 网络（严格两个）

```text
{facts.get('networks')}
```

- `default`（virbr0 `{facts.get('virbr0')}`）：管理网 —— SSH / Web UI / QGA，guest 固定 `192.168.122.50`
- `sunshine-private`（virbr1 `{facts.get('virbr1')}`）：**Moonlight 专用串流网**，guest `192.168.200.2`（隔离、不连外网）

`ufw` 已启用：`DEFAULT_FORWARD_POLICY="DROP"`、`DEFAULT_INPUT_POLICY="DROP"`。
本机 Moonlight 串流需要宿主机放行“guest→host”的新 UDP 视频流：

```bash
sudo ufw allow in on virbr1 to any port 47998:48010 proto udp
sudo ufw reload
```

局域网其他设备串流需要额外的 ufw/DNAT（见 `{repo}/linux-prerequisites.md` §6）。

---

## 3. Windows guest 现状（本次生成时实测）

| 项目 | 值 |
| --- | --- |
| 主机名 | `{facts.get('guest_hostname') or 'unknown'}` |
| 系统 | `{facts.get('guest_os')}` |
| Intel Arc 驱动 | `{facts.get('guest_driver')}` |
| Sunshine | `{facts.get('guest_sunshine')}` |
| Sunshine 任务 | `{facts.get('guest_sunshine_task')}` |
| VDD 设备状态 | `{facts.get('guest_vdd')}` |
| Moonlight（宿主客户端） | `{facts.get('moonlight')}` |
| 域状态 | `{facts.get('dom_state')}` |

```text
=== domiflist ===
{facts.get('domiflist') or 'unavailable'}

=== domblklist ===
{facts.get('domblklist') or 'unavailable'}

=== domifaddr (agent) ===
{facts.get('domifaddr') or 'unavailable'}
```

参考常量（脚本内置快照，guest 变更后会自动覆盖上述实测值）：

- 资源：4 vCPU / 6 GiB / 256 GiB；UUID `8353f52b-bbb1-4cfa-b85a-bc2e99175348`
- 网卡 1：MAC `52:54:00:30:cb:92` → `192.168.122.50/24`
- 网卡 2：MAC `52:54:00:40:cb:92` → `192.168.200.2/24`
- 系统盘：`{data_root}/libvirt/win11/win11.qcow2`（vda；安装 ISO 已摘除）
- 关键服务：QEMU-GA / sshd / SunshineService / Audiosrv（均自动启动）
- 显示：VDD 是唯一显示器（2560x1600@90、200% 缩放）；VirtIO 视频设备已从域中
  移除（该 Windows 构建只要有 VirtIO 显示路径，`SetDisplayConfig` 就报错）
- 音频：VB-Audio Virtual Cable（Sunshine 捕获 48kHz 立体声）
- 全局 UTF-8：ACP/OEMCP=65001（回滚 `restore-utf8.ps1 -Reboot`）
- 已装应用：Google Chrome、7-Zip、Notepad++、Git、winget、VC++ 2015-2022 (x64)

---

## 4. 日常操作（宿主机命令）

```bash
# 启动 / 优雅关机 / 重启
virsh -c qemu:///system start win11
virsh -c qemu:///system shutdown win11
virsh -c qemu:///system reboot win11

# 注意：修改持久化 XML 后必须 shutdown + start（reboot 不会换设备模型）

# 状态与验收
virsh -c qemu:///system domstate win11
virsh -c qemu:///system domiflist win11
virsh -c qemu:///system domblklist win11
bash {repo}/scripts/verify-stack.sh          # 期望 PASS=12 FAIL=0

# SSH / scp
ssh win-dev
scp 本地文件 win-dev:'C:/Admin/scripts/'

# QGA（网络挂了也能用）
virsh -c qemu:///system qemu-agent-command win11 '{{"execute":"guest-ping"}}'
virsh -c qemu:///system domifaddr win11 --source agent
```

### VNC 救援屏

```bash
virt-viewer -c qemu:///system win11

# 远程隧道：ssh -L 5901:127.0.0.1:5900 你的宿主机，然后
vncviewer 127.0.0.1:5901
```

显示器睡着时先唤醒：

```bash
virsh -c qemu:///system send-key win11 KEY_SCROLLLOCK
virsh -c qemu:///system screenshot win11 ~/win11-check.png
```

---

## 5. Sunshine / Moonlight

- Web UI：`https://192.168.122.50:47990`，账号 `sunshine` / `{sunshine_pw}`
- 端口：`47984-48010`（guest 防火墙已放行 TCP/UDP）
- 已配对客户端：`roth`（本机，无密码；配对证书在 `~/.config/Moonlight Game Streaming Project/`）
- 流量分工：**Moonlight 控制/视频/音频一律走专用串流网 `192.168.200.2`**；
  管理网 `192.168.122.50` 只负责 SSH / Web UI / QGA。
  宿主机 ufw 必须放行 virbr1 的 UDP `47998-48010`（见第 2 节），否则视频包会被
  INPUT DROP 静默丢弃（这就是“配对/音频正常但无视频画面”的根因之一）。

```bash
moonlight list 192.168.200.2

# 参考机无需任何模式切换（VDD 是唯一显示器）
# 窗口化串流（参考目标 16:10 2560x1600 @90Hz，走专用网，200% 缩放）
moonlight stream --resolution 2560x1600 --fps 90 --display-mode windowed --bitrate 50000 --video-codec auto 192.168.200.2 Desktop

# 可选：全屏 / 显式指定 AV1 或 HEVC
moonlight stream --resolution 2560x1600 --fps 90 --display-mode fullscreen --video-codec AV1 192.168.200.2 Desktop
moonlight stream --resolution 2560x1600 --fps 90 --display-mode fullscreen --video-codec HEVC 192.168.200.2 Desktop
# 3200x2000@165 仍可用，但接近 QSV 上限（见第 8 节）

# 仅在保留 VirtIO 视频设备的主机上需要显式切换：
# bash {repo}/scripts/host/stream-mode.sh on   # 串流前
# bash {repo}/scripts/host/stream-mode.sh off  # 串流后恢复
```

编码：`encoder=quicksync`，`av1_mode=0 / hevc_mode=0`（按编码器能力自动
通告，官方推荐值；2/3 才表示显式通告 8-bit/10-bit）。实测
`h264_qsv / hevc_qsv / av1_qsv` 均可用；2560x1600@90 下客户端 `auto` 走
HEVC，2026-08-26 实测连接→断开全流程干净。**帧率上限**：官方 Sunshine
写死 `async_depth=1`，3200x2000 全管线约 70-80 FPS（编码器本身 153 FPS）；
仓库补丁
`patches/sunshine-qsv-async-depth.patch` + `build-sunshine-patched.ps1` 增加
`qsv_async_depth` 配置项（见第 8 节）。**当前参考机 = 补丁版 +
`qsv_async_depth = 1`**：2026-08-26 实测 25 秒连接后强制断开，Sunshine 日志
`Session ended` 且进程保持存活；调高到 4 会触发断开时 Hang（勿在生产使用）。

**为什么不需要切模式**：本机 Windows 26H1 只要显示数据库里有 VirtIO 路径
（活跃、PnP 禁用或残留节点都一样），`SetDisplayConfig` 校验就返回
`ERROR_GEN_FAILURE`，Sunshine 无法把 VDD 设为主屏，串流显示“空副屏”（只有
壁纸、没有任务栏）。参考机已把 VirtIO 视频设备从域中移除并删除残留节点，
VDD 成为唯一显示器，显示 API 恢复（Sunshine 日志 `API is available: true`）。
代价是**没有 VNC 救援屏**，救援走 SSH + QGA。

新增设备配对（地址务必用专用网）：

```bash
moonlight pair --pin 2468 192.168.200.2
# 然后用上面 Web UI 账号登录，输入 Moonlight 显示的 4 位 PIN
```

guest 相关文件：
`C:\\Program Files\\Sunshine\\config\\sunshine.conf` / `sunshine_state.json` /
`sunshine.log`；启动入口是计划任务 `SunshineUser`（必须带
`WorkingDirectory=C:\\Program Files\\Sunshine`），包装器
`C:\\Admin\\scripts\\start-sunshine.ps1` 负责开机顺序（先等 VDD + Arc VF）。

---

## 6. 故障恢复手册（按严重程度）

### A. Sunshine 起不来 / 日志报 `Failed to locate an output device`

```powershell
# guest 上执行
C:\\Admin\\scripts\\fix-display-topology.ps1
Start-ScheduledTask -TaskName SunshineUser   # 不要再用 SunshineService（Manual/Stopped）
```

登录任务 `FixDisplayTopology` 开机自动执行同一逻辑。不要裸用
`DisplaySwitch /internal → /extended`，它会把 VDD 踢掉。

### A2. Sunshine 启动即崩溃（0xC0000005），日志含 `Couldn't compile [assets/shaders/...] 0x80070003`

`SunshineUser` 任务的 `WorkingDirectory` 丢了（Task Scheduler 默认
`C:\\Windows\\System32`），Sunshine 找不到自己的 shader 资产。重建任务：

```powershell
C:\\Admin\\scripts\\setup-sunshine-user-task.ps1
Stop-ScheduledTask -TaskName SunshineUser
Get-Process Sunshine -ErrorAction SilentlyContinue | Stop-Process -Force
Start-ScheduledTask -TaskName SunshineUser
```

正常日志应以 `Compiled shaders` + `Found H.264 encoder: h264_qsv` 开头，
进程保持存活。

### B. VNC 黑屏但 VM 健康

先 `send-key win11 KEY_SCROLLLOCK` 唤醒；仍黑则跑 `fix-display-topology.ps1`，
或 QGA 跑救援脚本（禁用 VDD 并重启，回到 VirtIO 救援屏）：

```bash
virsh -c qemu:///system qemu-agent-command win11 \\
  '{{"execute":"guest-exec","arguments":{{"path":"C:\\\\Windows\\\\System32\\\\WindowsPowerShell\\\\v1.0\\\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\\\Admin\\\\scripts\\\\display-rescue.ps1"],"capture-output":true}}}}'
```

恢复 VDD：`pnputil /enable-device "ROOT\\DISPLAY\\0000"` 后重跑
`fix-display-topology.ps1`。**Intel 驱动升级后** VDD 可能直接缺失或 Error，
`pnputil` 也救不回来，必须重建根设备：

```powershell
C:\\Admin\\VDD\\devcon.exe install C:\\Admin\\VDD\\MttVDD.inf Root\\MttVDD
C:\\Admin\\scripts\\fix-display-topology.ps1
Start-ScheduledTask -TaskName SunshineUser
```

完整有序升级（停 Sunshine → 禁用 VDD → 安装驱动 → 重启 → 重建 VDD → 启动）
由 `C:\\Admin\\scripts\\upgrade-intel-driver.ps1` 一条命令完成，重启后用
RunOnce 自动续跑。

### C. SSH 也断了（QGA 仍通）

上面的 QGA `guest-exec` 就是逃生通道，不依赖 Windows 网络栈。

### D. 串流无视频（Moonlight 提示检查 UDP 47998/48000）

先确认宿主机 ufw 有这条规则（视频是 guest→host 的新入站 UDP 流，会被默认
INPUT DROP 拦截；音频探测因为是已建立连接的回包所以能过）：

```bash
sudo ufw allow in on virbr1 to any port 47998:48010 proto udp
sudo ufw reload
```

再确认会话确实走专用网：guest 上 `netstat -an | findstr 48010` 应看到
`192.168.200.2:48010` 与 `192.168.200.1` 的连接。

### E. 全黑 + QGA 也断

1. `virsh -c qemu:///system send-key win11 KEY_LEFTMETA KEY_P`（Win+P）+ 方向键循环；
2. 还不行就 `virsh -c qemu:///system destroy win11` 强停后 `start win11`；
3. 最后手段：VNC over SSH 隧道进安全模式卸载 VDD。

### F. 凭据状态自查（不打印明文）

```powershell
# guest 上执行
C:\\Admin\\scripts\\get-credentials-status.ps1
```

全部 `CRED OK` 即正常；有 `MISS` 按第 1 节同步密码副本。

### G. 轮换密码

```powershell
net user vmadmin <新密码>
C:\\Admin\\scripts\\set-autologon-permanent.ps1 -UserName vmadmin -Password <新密码>

C:\\Admin\\scripts\\set-sunshine-creds.ps1 -Username sunshine -Password <新密码>
# 不想立刻重启加 -NoReboot
```

改完必须同步：宿主 `{repo}/secrets.local.env` + guest
`C:\\Admin\\config\\local-secrets.json`，然后重新生成本手册。完整流程见 `{repo}/CREDENTIALS.md`。

---

## 7. 文件与路径速查

| 位置 | 内容 |
| --- | --- |
| `{repo}` | 全部脚本/文档/模板（git 仓库） |
| `{repo}/secrets.local.env` | 明文密码（git-ignored） |
| `{repo}/admin_ed25519` / `.pub` | SSH 私钥 / 公钥（git-ignored，与 `~/.ssh/id_ed25519` 相同） |
| `{out}` | 本手册 |
| `{data_root}/libvirt/win11/win11.qcow2` | guest 系统盘 |
| `{data_root}/iso/Win11.iso` | 重装用 Windows ISO（当前未挂载） |
| `/var/lib/libvirt/images/virtio-win.iso` | VirtIO/QGA 驱动 ISO（当前未挂载） |
| guest `C:\\Admin\\scripts\\` | 全部 PowerShell 运维脚本 |
| guest `C:\\Admin\\scripts\\stream-display-mode.ps1` | 仅保留 VirtIO 的主机使用：串流/救援模式切换（含 Sunshine 重启） |
| guest `C:\\Admin\\config\\local-secrets.json` | guest 侧密码副本 |
| guest `C:\\VirtualDisplayDriver\\vdd_settings.xml` | VDD 分辨率/刷新率配置（含 3200x2000@165） |
| guest `C:\\Admin\\VDD` / `C:\\Admin\\VBCABLE` / `C:\\Admin\\tools` | 驱动包与工具（devcon、MultiMonitorTool） |
| guest `C:\\Admin\\tools\\ffmpeg\\` | FFmpeg/ffprobe/ffplay（QSV 诊断与压测） |
| guest `C:\\Admin\\logs\\` | 安装/升级/启动/拓扑等全部运维日志 |
| guest `C:\\Admin\\build\\` | Sunshine 源码与补丁构建（`sunshine-src`、`sunshine-stage`） |
| `{repo}/patches/` | `sunshine-qsv-async-depth.patch`（构建补丁） |

---

## 8. 已知限制（报喜也报忧）

- ViGEmBus 未安装：手柄支持不可用，Sunshine 启动有一行非致命警告。
- Windows 26H1 拒绝仅第三方代码签名 CA 的内核驱动（如 VDD 项目 Virtual Audio Driver，
  报 `CM_PROB_UNSIGNED_DRIVER / 0xC0000428`），音频使用签名的 VB-CABLE。
- CachyOS 不在 Intel GFX SR-IOV 官方验证矩阵（官方为 Ubuntu 24.04.4 + kernel 6.18）。
- Intel 显卡驱动升级已验证一次（8356 → 8974）：升级后 VDD 必须用 devcon
  重建（`pnputil /enable-device` 不够），流程见 `upgrade-intel-driver.ps1`。
- **帧率上限**：官方 Sunshine 的 QSV 写死 `async_depth=1`，3200x2000 下实测
  全管线约 70-80 FPS（HEVC），即便编码器本身可到 ~153 FPS。仓库补丁
  `patches/sunshine-qsv-async-depth.patch` 增加 `qsv_async_depth` 配置项，
  `build-sunshine-patched.ps1` 负责重编；参考机当前安装补丁版并保持
  `qsv_async_depth = 1`（与官方行为一致，连接/断开稳定）。把该值调到 4 后，
  客户端断开时 Sunshine 会 `Fatal: Hang detected!` 并退出；2/3/4 仅作实验，
  必须通过真实连接→断开测试后再用。未做脚本化满帧率压测，实际持续帧率以
  日常使用为准。**参考目标为 2560x1600@90 + 200% 缩放**；165Hz@3200x2000
  接近该 VF 的 QSV 极限，稳定满 165 FPS 可能需要降到 2560x1600 或更轻的
  preset。桌面静止时帧率低是 DDAPI 设计行为，不是故障。
- **显示 API 冲突 / 无 VNC**：本机只要显示数据库里有 VirtIO 路径，
  `SetDisplayConfig` 就返回 `ERROR_GEN_FAILURE`，Sunshine/MultiMonitorTool
  无法把 VDD 设为主屏，串流显示空副屏。参考机已**永久移除 VirtIO 视频设备**
  （域 XML `type='none'` + 删除残留 PnP 节点），VDD 是唯一显示器；因此没有
  VNC 救援屏，救援走 SSH + QGA。保留 VirtIO 的主机才需要
  `stream-mode.sh on|off`（会重启 Sunshine，勿在会话中切换）。
- 局域网其他设备串流未验证（需要 ufw/DNAT，见 linux-prerequisites.md §6）。
- guest 通过 libvirt NAT 上外网默认被 ufw 挡住（`DEFAULT_FORWARD_POLICY="DROP"`）。

---

*由 `{repo}/scripts/host/gen-local-manual.py` 于 {now} 生成。仓库 HEAD
`{facts.get('git_head')}`。*
*密码/状态变化后：重新运行上面的一键命令即可。*
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output-dir",
        default=os.environ.get("OUTPUT_DIR", ""),
        help="Directory for the generated manual (default: user download dir)",
    )
    args = parser.parse_args()

    secrets = load_secrets(SECRETS)
    if "ADMIN_PASSWORD" not in secrets or "SUNSHINE_WEB_PASSWORD" not in secrets:
        print(
            f"ERROR: {SECRETS} is missing ADMIN_PASSWORD/SUNSHINE_WEB_PASSWORD.\n"
            "Copy secrets.local.env.example to secrets.local.env and fill it in.",
            file=sys.stderr,
        )
        return 1

    out_dir = Path(args.output_dir) if args.output_dir else download_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "win11-vm-manual.md"

    facts = live_facts()
    text = render(secrets, facts, out)
    out.write_text(text, encoding="utf-8")
    os.chmod(out, 0o600)

    print(f"written: {out} ({out.stat().st_size} bytes, mode 0600)")
    if facts.get("ssh_healthy") != "yes":
        print("note: live SSH probe failed (sandbox/container quirk); manual still generated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

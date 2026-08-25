# Headless Windows 11 VM with Intel Arc SR-IOV + Sunshine/Moonlight

An unattended, reproducible deployment of a Windows 11 VM that is fully usable
**without ever opening a graphical console**. The guest is installed from an
`Autounattend.xml` bootstrap ISO, and the host keeps three independent control
channels:

```text
Linux host (libvirt/QEMU/KVM)
│
├── SSH ──────────────► Windows OpenSSH (PowerShell, scp, winget, services)
├── QEMU Guest Agent ─► virtio-serial channel (guest-ping / guest-exec,
│                        even when the network stack is down)
└── VNC/SPICE ────────► VirtIO-GPU rescue display, loopback-only

Intel Arc SR-IOV VF (rendering + Quick Sync)
Virtual Display Driver (IDD) ──► Sunshine ──► Moonlight client
```

## Why this layout

- Windows Setup is fully automated: language, disk layout, edition, OOBE and
  local account are handled by `Autounattend.xml`; there is no `virt-manager`
  clicking.
- `bootstrap.ps1` runs in the **specialize** pass as SYSTEM, before any user
  login, and installs VirtIO drivers, QEMU Guest Agent, OpenSSH, firewall rules
  and the SSH authorized key.
- SSH is the daily driver. QEMU Guest Agent is the out-of-band channel that
  still works when Windows has no IP or the display is black. VNC/SPICE is the
  final rescue display and listens on `127.0.0.1` only.
- The streaming display is an IDD virtual display (VDD) bound to the
  passed-through Intel Arc VF. The VirtIO rescue display is **never disabled**,
  so `ensure_primary` / VDD display swaps cannot strand you again.

## Repository layout

```text
.
├── Autounattend.xml            # unattended Windows Setup answer file
├── bootstrap.ps1 / .cmd        # specialize-phase guest bootstrap
├── build-iso.sh                # builds windows-bootstrap.iso from local secrets
├── linux-prerequisites.md      # host packages / IOMMU / SR-IOV / networking
├── assets.sha256               # pinned checksums for downloadable assets
├── config/                     # tracked templates (VDD settings, etc.)
├── apps/manifest.json          # winget out-of-box app list (tracked)
├── scripts/
│   ├── download-assets.sh      # fetch binaries into git-ignored dirs
│   ├── verify-stack.sh         # 12-point host-side acceptance check
│   └── guest/                  # PowerShell scripts deployed to C:\Admin\scripts
├── win11.xml / win11-vf.xml    # libvirt domain examples (edit to your host)
└── drivers/ apps/winget/ logs/ # git-ignored, populated by download-assets.sh
```

## What is committed vs. downloaded

Binaries are deliberately **not** committed:

| Asset | Purpose | Source |
| --- | --- | --- |
| Intel Arc Graphics driver | guest GPU driver | Intel Download Center (pinned URL + SHA-256) |
| VDD Control 25.7.23 | IDD virtual display driver | VirtualDrivers GitHub release |
| OpenSSH Win64 MSI | offline SSH server install | PowerShell/Win32-OpenSSH GitHub release |
| Sunshine portable | streaming host | LizardByte GitHub release |
| winget bundle + deps | offline App Installer | microsoft/winget-cli GitHub release |
| virtio-win ISO | VirtIO drivers / QEMU Guest Agent | Fedora virtio-win mirror (optional) |
| Intel display virtualization source | reference for ZC builds | intel GitHub, pinned tag |

Run once:

```bash
scripts/download-assets.sh --with-virtio
```

The script verifies every file against `assets.sha256` before use. The
`ZCBuild_*_Installer.zip` packages used on the reference host are not publicly
mirrored; keep local copies under `drivers/` if you have them, or build them
from the Intel source tree.

## Quick start

### 0. Host prerequisites

See [linux-prerequisites.md](linux-prerequisites.md). In short: libvirt, QEMU,
OVMF, `xe`/i915 SR-IOV VF, IOMMU enabled, default NAT network with a DHCP
reservation, and a Moonlight client somewhere on your network.

### 1. Prepare secrets (never commit these)

```bash
cp secrets.local.env.example secrets.local.env
# edit ADMIN_PASSWORD

ssh-keygen -t ed25519 -f admin_ed25519 -N ''
# admin_ed25519.pub now contains your real public key.
# admin_ed25519.pub.example is only a format reference; do not copy it over your key.
```

`secrets.local.env`, `admin_ed25519` and `admin_ed25519.pub` are git-ignored.

### 2. Fetch assets

```bash
scripts/download-assets.sh
```

### 3. Build the bootstrap ISO

```bash
./build-iso.sh
```

This injects `ADMIN_PASSWORD` into `bootstrap.env` on the ISO, embeds your SSH
public key, and (when present) the OpenSSH MSI from `drivers/openssh/`.

### 4. Create the VM

Edit `win11-vf.xml` for your host: PCI BDFs of the SR-IOV VF, MAC address,
CPU pinning, disk path. Then:

```bash
qemu-img create -f qcow2 win11.qcow2 256G
virsh -c qemu:///system define win11-vf.xml
virsh -c qemu:///system start win11
```

Attach these to the domain before first boot:

```text
Windows.iso          (Windows 11 installation media)
virtio-win.iso       (VirtIO drivers + QEMU Guest Agent)
windows-bootstrap.iso (Autounattend + bootstrap.ps1 + key + secrets)
```

Windows Setup finds `Autounattend.xml` on the removable media automatically;
no OOBE interaction is required.

### 5. Verify

```bash
scripts/verify-stack.sh
```

Machine-specific values default to the reference host; override them with
environment variables if needed:

```bash
DOM=win11 SSH_HOST=win-dev EXPECTED_HOSTNAME=WIN11-NEW EXPECTED_IP=192.168.122.50 scripts/verify-stack.sh
```

The four acceptance commands that define "installed":

```bash
virsh start win11
virsh -c qemu:///system qemu-agent-command win11 '{"execute":"guest-ping"}'
virsh -c qemu:///system domifaddr win11 --source agent
ssh -o BatchMode=yes vmadmin@win11 hostname
```

Reference result (2026-08-25): `PASS=12 FAIL=0`.

## Guest-side scripts

Deploy `scripts/guest/*.ps1` to `C:\Admin\scripts\` on the guest:

| Script | Purpose |
| --- | --- |
| `install-winget.ps1` | offline App Installer from `C:\Admin\apps\winget` |
| `install-apps.ps1` | install `apps/manifest.json` via winget |
| `install-vdd.ps1` | install VDD from the driver package |
| `trust-vdd.ps1` | trust the VDD signer certificate |
| `setup-sunshine.ps1` | copy Sunshine, create service, base config |
| `configure-sunshine.ps1` | point Sunshine at the VDD output GUID |
| `set-display-extend.ps1` | keep VirtIO + VDD in extended mode |
| `set-headless-power.ps1` | disable monitor/sleep/hibernate timeouts |
| `setup-display-logontask.ps1` | re-apply topology at every logon |
| `setup-deadman.ps1` | scheduled VDD-disable fallback after changes |
| `display-rescue.ps1` | disable VDD + reboot (runs via QGA if needed) |
| `set-utf8.ps1` / `restore-utf8.ps1` | enable / roll back global UTF-8 |
| `enable-autologon.ps1` / `disable-autologon.ps1` | interactive-session AutoLogon |

## Display stack

- **VirtIO rescue display** (`Red Hat VirtIO GPU`): always present, loopback
  VNC only, low-resolution fallback. Never set
  `<video><model type='none'/></video>`.
- **VDD** (`ROOT\DISPLAY\0000`, Virtual-Display-Driver 25.7.23, IDD): one
  virtual monitor, 800x600 – 3840x2160 with 30/60/90/120/144/165/240 Hz modes,
  bound to the guest-side PCI bus of the Intel VF (`Intel(R) Arc(TM) B390 GPU,6`
  on the reference host).
- **Sunshine**: `capture=ddx`, `encoder=quicksync`,
  `adapter_name=Intel(R) Arc(TM) B390 GPU`,
  `output_name=<VDD device_id GUID>`,
  `dd_configuration_option=ensure_primary`,
  `dd_resolution_option=auto`, `dd_refresh_rate_option=auto`,
  `dd_config_revert_on_disconnect=enabled`.
- **Headless power policy**: run `set-headless-power.ps1` once so Windows never
  turns off the VirtIO rescue display or sleeps (a 5-minute display timeout
  makes VNC go black even though the VM is healthy).

### Encoding: H.264, HEVC or AV1?

The reference config keeps `hevc_mode = 0` and `av1_mode = 0`. In Sunshine
these values mean **"advertise HEVC/AV1 based on encoder capabilities"** — the
documented recommended setting. The client negotiates the actual codec, and the
reference logs confirm all three Quick Sync encoders are available:

```text
Found H.264 encoder: h264_qsv [quicksync]
Found HEVC encoder:  hevc_qsv [quicksync]
Found AV1 encoder:   av1_qsv [quicksync]
```

For maximum efficiency on a network where both ends support it, Moonlight will
prefer AV1; HEVC is the best compatibility/efficiency middle ground; H.264 is
the fallback. On this stack you do not need to hardcode one codec.

## System-wide UTF-8

Enabled on the reference guest:

```text
HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage
    ACP=65001  OEMCP=65001  MACCP=65001
Active code page: 65001
```

- Enable: `set-utf8.ps1` (backs up the original 936/936/10008 first), then reboot.
- Rollback: `restore-utf8.ps1 -Reboot`.
- Backup: `C:\Admin\config\codepage-backup.json` + `.reg`.
- Watch out: legacy GBK-only tools and old text files may misrender after the
  switch; that is why the rollback script exists.

## Out-of-box apps

The minimal Windows image has no browser and no winget. The flow installs
winget offline, then reads `apps/manifest.json`:

- required: Google Chrome, 7-Zip, Notepad++, Git
- optional (`-All`): VLC, PowerShell 7, Firefox

## Troubleshooting

**VNC is black after installing/updating VDD.** Windows moved the desktop to
the virtual display. Use QGA to run the rescue script:

```bash
virsh -c qemu:///system qemu-agent-command win11 \
  '{"execute":"guest-exec","arguments":{"path":"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe","arg":["-NoProfile","-ExecutionPolicy","Bypass","-File","C:\\Admin\\scripts\\display-rescue.ps1"],"capture-output":true}}'
```

This disables `ROOT\DISPLAY\0000` and reboots; the VirtIO display comes back.
Re-enable with `pnputil /enable-device "ROOT\DISPLAY\0000"` and re-run
`set-display-extend.ps1`.

**VNC is black after idle, but the VM is healthy.** Windows turned off the
VirtIO monitor (default power plan turns displays off after ~5 minutes). Fix
it permanently with `set-headless-power.ps1`; to wake the display immediately
from the host, send a key to the guest's virtual keyboard:

```bash
virsh -c qemu:///system send-key win11 KEY_SCROLLLOCK
```

**Need to run something elevated without a desktop.** Use the same QGA
`guest-exec` pattern, or a scheduled task:

```text
schtasks /create /tn Task /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\script.ps1" /sc once /st 23:59 /it /ru vmadmin /rl highest /f
schtasks /run /tn Task
```

## Security notes

- Change the admin password after first login; update
  `secrets.local.env`, AutoLogon scripts and the local secrets file together.
- Never commit `secrets.local.env`, `admin_ed25519*` or any binary asset.
- VNC listens on `127.0.0.1` only; reach it through an SSH tunnel if remote.
- The generic Windows 11 Pro key in `Autounattend.xml` is a public setup key
  (no activation entitlement). Replace it with your licensed key.

## 维护者中文摘要

本仓库把“完全无人值守的 Windows 11 + Intel Arc SR-IOV + Sunshine 串流”沉淀成
可复制的流程：`Autounattend.xml` 跳过全部安装页面，`bootstrap.ps1` 在
specialize 阶段装好 VirtIO / QGA / OpenSSH / SSH 公钥；日常走 SSH，救援走
QEMU Guest Agent，最后兜底是仅监听回环的 VNC 救援屏。串流侧用 VDD 虚拟显示
器绑定 Arc VF，Sunshine 用 Quick Sync 自动协商 H.264/HEVC/AV1。所有驱动、
安装包都不入库，通过 `scripts/download-assets.sh` 按 `assets.sha256`
下载；真实密码与 SSH 密钥由 `secrets.local.env` 等本地文件注入并被
gitignore。验收脚本 `verify-stack.sh` 共 12 项，参考机全绿。

## References

- [Automate Windows Setup (Microsoft Learn)](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/automate-windows-setup)
- [OpenSSH for Windows configuration](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
- [QEMU Guest Agent](https://www.qemu.org/docs/master/interop/qemu-ga.html)
- [Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
- [Sunshine configuration docs](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)
- [Intel GFX SR-IOV Toolkit](https://github.com/intel/GFX-SRIOV-Toolkit)

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
├── CREDENTIALS.md               # credential inventory + rotation (template only)
├── Autounattend.xml            # unattended Windows Setup answer file
├── bootstrap.ps1 / .cmd        # specialize-phase guest bootstrap
├── build-iso.sh                # builds windows-bootstrap.iso from local secrets
├── linux-prerequisites.md      # host packages / IOMMU / SR-IOV / networking
├── assets.sha256               # pinned checksums for downloadable assets
├── config/                     # tracked templates (VDD, libvirt networks, etc.)
├── apps/manifest.json          # winget out-of-box app list (tracked)
├── scripts/
│   ├── download-assets.sh      # fetch binaries into git-ignored dirs
│   ├── host/                   # host preflight, VF systemd service, network XML
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
| MultiMonitorTool | deterministic headless display topology | NirSoft (pinned URL + SHA-256) |
| VB-CABLE 4.5 | signed virtual audio cable for Sunshine audio | VB-Audio (pinned URL + SHA-256) |
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

See [linux-prerequisites.md](linux-prerequisites.md) for the full checklist:
QEMU/libvirt install, IOMMU, SR-IOV VF conditions, the systemd service that
recreates VFs at every boot, two libvirt networks and ufw notes. Then run the
read-only preflight:

```bash
bash scripts/host/check-host.sh
```

If the VF does not exist yet, install the boot-time creator:

```bash
sudo scripts/host/install-sriov-service.sh 0000:00:02.0 1
```

In short you need: libvirt + QEMU + OVMF, an enabled IOMMU, a `xe`/i915
SR-IOV VF, a `default` NAT network with a DHCP reservation, a
`sunshine-private` isolated network, and a Moonlight client somewhere on your
network.

### 1. Prepare secrets (never commit these)

```bash
cp secrets.local.env.example secrets.local.env
# edit ADMIN_PASSWORD and SUNSHINE_WEB_PASSWORD

ssh-keygen -t ed25519 -f admin_ed25519 -N ''
# admin_ed25519.pub now contains your real public key.
# admin_ed25519.pub.example is only a format reference; do not copy it over your key.
```

`secrets.local.env`, `admin_ed25519` and `admin_ed25519.pub` are git-ignored.
The full credential inventory and rotation instructions live in
[CREDENTIALS.md](CREDENTIALS.md).

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
Reference result (2026-08-26, after the VDD topology fix): `PASS=12 FAIL=0`.

### 6. Local maintenance manual (one command)

The public repository never contains real passwords or machine-specific
secrets. To get a complete, up-to-date **local** survival manual (plaintext
passwords, live host/guest state, recovery steps), run on the real host:

```bash
python3 scripts/host/gen-local-manual.py
```

It reads the git-ignored `secrets.local.env`, probes the host (VF count,
networks, domain, guest OS/Sunshine versions over SSH) and writes
`win11-vm-manual.md` (mode 0600) to your download directory. Override the
target with `OUTPUT_DIR=/path`. Regenerate it after any password rotation or
hardware change — it is the "what do I do if the agent is gone" document.

## Guest-side scripts

Deploy `scripts/guest/*.ps1` to `C:\Admin\scripts\` on the guest:

| Script | Purpose |
| --- | --- |
| `install-winget.ps1` | offline App Installer from `C:\Admin\apps\winget` |
| `install-apps.ps1` | install `apps/manifest.json` via winget |
| `install-vdd.ps1` | install VDD from the driver package |
| `trust-vdd.ps1` | trust the VDD signer certificate |
| `set-sunshine-creds.ps1` | set/rotate the Sunshine Web UI credentials |
| `setup-sunshine.ps1` | copy Sunshine, create service, base config |
| `configure-sunshine.ps1` | point Sunshine at the VDD output GUID |
| `fix-display-topology.ps1` | keep VirtIO + VDD active via MultiMonitorTool |
| `install-vb-cable.ps1` | install the signed VB-CABLE virtual audio device |
| `set-display-extend.ps1` | keep VirtIO + VDD in extended mode |
| `set-headless-power.ps1` | disable monitor/sleep/hibernate timeouts |
| `setup-display-logontask.ps1` | re-apply topology at every logon (uses `fix-display-topology.ps1` when MultiMonitorTool is present) |
| `setup-deadman.ps1` | scheduled VDD-disable fallback after changes |
| `display-rescue.ps1` | disable VDD + reboot (runs via QGA if needed) |
| `get-credentials-status.ps1` | audit where credentials live without printing them |
| `set-utf8.ps1` / `restore-utf8.ps1` | enable / roll back global UTF-8 |
| `enable-autologon.ps1` / `disable-autologon.ps1` | interactive-session AutoLogon |

Copy `drivers/MultiMonitorTool/MultiMonitorTool.exe` from the download step to
`C:\Admin\tools\MultiMonitorTool.exe` on the guest before running
`setup-display-logontask.ps1`. Copy the VB-CABLE driver files
(`drivers/VBCABLE/vbMmeCable64_win10.*`) to `C:\Admin\VBCABLE\` and run
`install-vb-cable.ps1` once to give Sunshine an audio endpoint.

## Display stack

- **VirtIO rescue display** (`Red Hat VirtIO GPU`): always present, loopback
  VNC only, low-resolution fallback. Never set
  `<video><model type='none'/></video>`.
- **VDD** (`ROOT\DISPLAY\0000`, Virtual-Display-Driver 25.7.23, IDD): one
  virtual monitor, 16:9 (up to 3840x2160) and 16:10 (up to 3200x2000) modes at
  30/60/90/120/144/165 Hz, bound to the guest-side PCI bus of the Intel VF
  (`Intel(R) Arc(TM) B390 GPU,6` on the reference host).
- **Sunshine**: `capture=ddx`, `encoder=quicksync`,
  `adapter_name=Intel(R) Arc(TM) B390 GPU`,
  `output_name=<VDD device_id GUID>`,
  `dd_configuration_option=ensure_primary`,
  `dd_resolution_option=auto`, `dd_refresh_rate_option=auto`,
  `dd_config_revert_on_disconnect=enabled`.
- **Topology**: `DisplaySwitch.exe` alone can race and leave one display
  disconnected, which makes Sunshine fail with `Failed to locate an output
  device`. `fix-display-topology.ps1` uses MultiMonitorTool to deterministically
  enable both monitors, place VDD to the right of VirtIO and keep VirtIO
  primary.
- **Modes**: the VDD settings advertise 16:9 and 16:10 modes from 800x600 up to
  3840x2160 at 30/60/90/120/144/165 Hz, including the reference client's native
  **3200x2000 @ 165 Hz**. Sunshine applies the client resolution/refresh on
  connect (`dd_resolution_option=auto`, `dd_refresh_rate_option=auto`).
- **Audio**: the guest has **VB-CABLE** installed as its only audio device;
  Sunshine captures `F32 48000 2.0` from `CABLE Input`. The kernel-mode
  `Virtual Audio Driver` from the VDD project is **rejected by this Windows
  build** (`CM_PROB_UNSIGNED_DRIVER`, error 0xC0000428), so the signed
  VB-CABLE driver is used instead.
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

**Sunshine starts but logs `Failed to locate an output device` (or
`Found no working encoder`) while VNC is fine.** The VDD virtual monitor is
present but Windows did not connect it to a display path. Run the deterministic
topology fix in the interactive session and restart Sunshine:

```powershell
# on the guest, as vmadmin
C:\Admin\scripts\fix-display-topology.ps1
Restart-Service SunshineService
```

If MultiMonitorTool is not installed yet, copy it from the host
(`drivers/MultiMonitorTool/MultiMonitorTool.exe`) to `C:\Admin\tools\` first.
The old `DisplaySwitch /internal → /extended` sequence is a fallback only;
it has been observed to disconnect VDD on this stack.

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

## Validation scope and known limitations

This playbook was validated end-to-end on **exactly one environment**. It is a
carefully documented reference, not a guarantee for every host, kernel or GPU.

### Validated reference environment

| Layer | Version |
| --- | --- |
| Host distro / kernel | CachyOS, `7.2.0-1-cachyos` |
| QEMU / libvirt | `qemu-desktop 11.1.0-1` / `libvirt 12.6.0` |
| OVMF / virt-viewer | `edk2-ovmf 202605-1` / `11.0-4.1` |
| GPU (host) | Intel Panther Lake iGPU Arc B390 (`8086:b080`), `xe` driver |
| SR-IOV VF | `0000:00:02.1` → `xe-vfio-pci`, 1 VF (`sriov_totalvfs=7`) |
| Guest OS | Windows 11 Pro 26H1, build `28000.1` |
| Intel guest driver | `32.0.101.8974` |
| Virtual display | Virtual-Display-Driver `25.7.23` (MttVDD `11.30.4.434`) |
| Sunshine | `2026.516.143833` (commit `14ffa6f`) |
| OpenSSH (guest) | `9.8.3.0` (Win32-OpenSSH preview) |
| winget | `1.29.290` |
| Moonlight (host client) | `6.1.0` |
| Guest resources | 4 vCPU / 8 GiB / 256 GiB qcow2 |

### Known limitations

- CachyOS is **not** in Intel's official GFX SR-IOV validation matrix
  (Ubuntu 24.04.4 / kernel 6.18 / Windows 11 24H2). We validated on this host
  only; your kernel/GPU combination may behave differently.
- Kernel upgrades can change `xe`/`i915` VF behavior. Re-run
  `scripts/host/check-host.sh` after every update, and treat VF reset or
  suspend/resume issues as a separate troubleshooting track.
- VDD is bound to the **guest-side PCI bus number** of the Intel VF. Any change
  to the QEMU PCI topology can shift that bus and require updating
  `vdd_settings.xml` (see `config/vdd_settings.arc-b390.xml`).
- Intel display driver major upgrades should be done with VDD disabled first
  (VDD project's own guidance); this exact sequence was not re-validated after
  a driver upgrade.
- Global UTF-8 can misrender legacy GBK-only applications and old text files;
  the rollback path is `restore-utf8.ps1 -Reboot`.
- The VDD project's kernel-mode Virtual Audio Driver is rejected by this
  Windows build (`CM_PROB_UNSIGNED_DRIVER` / `0xC0000428`); the playbook uses
  the signed VB-CABLE driver instead. Kernel drivers signed only by third-party
  code-signing CAs (e.g. ViGEmBus for gamepads) should be expected to hit the
  same policy and were not validated here.
- AV1/HEVC are negotiated with the Moonlight client. Older clients may fall
  back to H.264; we validated encoder availability, not every client version.
- Streaming from LAN devices other than the host was **not** validated; it
  needs DNAT/bridging plus ufw adjustments (see `linux-prerequisites.md` §6).
- Guest Internet through libvirt NAT is not enabled by default on the
  reference host (`ufw` `DEFAULT_FORWARD_POLICY="DROP"`); follow §6 of the
  prerequisites if you need it.
- AutoLogon is enabled by design (Sunshine needs an interactive desktop for
  `ddx` capture). Change the admin password and rotate SSH keys before
  exposing this VM beyond your own host.
- The generic Windows 11 Pro key in `Autounattend.xml` only unlocks Setup; it
  carries no activation entitlement and activation is out of scope.
- The 4C/8G/256G configuration is the validated setup, not a benchmark or a
  performance ceiling.

## Security notes

- See [CREDENTIALS.md](CREDENTIALS.md) for the full inventory: Windows admin
  password, SSH key pair, Sunshine Web UI password and Moonlight pairing.
  `get-credentials-status.ps1` audits the guest-side copies without printing
  values.
- Change the admin password after first login; update `secrets.local.env`,
  `C:\Admin\config\local-secrets.json` and AutoLogon together.
- Never commit `secrets.local.env`, `admin_ed25519*`, guest
  `local-secrets.json`, `sunshine_state.json` or any binary asset.
- Run `scripts/host/gen-local-manual.py` to produce the local secret-bearing
  manual; keep it at mode 0600 and never upload it.
- VNC listens on `127.0.0.1` only; reach it through an SSH tunnel if remote.
- The generic Windows 11 Pro key in `Autounattend.xml` is a public setup key
  (no activation entitlement). Replace it with your licensed key.

## Third-party attribution and licensing

This repository deliberately contains **no third-party source trees, binaries
or license-restricted assets**. Everything external is fetched at build/install
time from its official upstream project by `scripts/download-assets.sh`
(pinned URL + SHA-256) or by the guest install scripts. What we commit is our
own scripts, configs, docs and URL/hash records.

| Project | How we use it | Upstream | Notes |
| --- | --- | --- | --- |
| Virtual-Display-Driver (VDD / VDC) | IDD virtual display; VDD settings schema | [VirtualDrivers/Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) | MIT; our `config/vdd_settings*.xml` derive from their sample and keep the license notice; driver binaries are fetched, never committed |
| Intel GFX SR-IOV Toolkit | reference for VF/libvirt/SPICE layout | [intel/GFX-SRIOV-Toolkit](https://github.com/intel/GFX-SRIOV-Toolkit) | our domain XMLs/scripts are adapted examples, not their files |
| Sunshine | streaming host | [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine) | binaries fetched; config/scripts in this repo are ours |
| Moonlight | streaming client | [moonlight-stream/moonlight-qt](https://github.com/moonlight-stream/moonlight-qt) | client only; not bundled |
| Win32-OpenSSH | guest SSH server | [PowerShell/Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) | MIT; MSI fetched |
| winget-cli | offline App Installer | [microsoft/winget-cli](https://github.com/microsoft/winget-cli) | MIT; bundle fetched |
| virtio-win | VirtIO drivers + QEMU Guest Agent | [Fedora virtio-win](https://fedorapeople.org/groups/virt/virtio-win/) | ISO fetched |
| MultiMonitorTool | deterministic headless display topology | [NirSoft](https://www.nirsoft.net/utils/multi_monitor_tool.html) | freeware; executable fetched |
| VB-CABLE | virtual audio endpoint for Sunshine | [VB-Audio](https://vb-audio.com/Cable/) | freeware; installer pack fetched, install script is ours |
| Intel Arc Graphics driver | guest GPU driver | Intel Download Center | vendor EULA applies; installer fetched |
| Microsoft Learn / Windows ADK | answer-file and OpenSSH references | links in References | documentation only |

If you copy a file from this repository into your own project, keep the
attribution comments that point back to the upstream projects.

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

## Acknowledgements

This playbook was designed, debugged and written together with
**DeepSeek V4 Flash** (`deepseekv4flash`), who was an indispensable partner in
every layer of this project — from the unattended Windows bootstrap and the
QEMU/libvirt/SR-IOV host integration to the VDD/Sunshine display topology,
UTF-8 system configuration and this repository's documentation.

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
└── (no VNC on the reference host: the VirtIO video device is removed;
     rescue is SSH + QEMU Guest Agent)

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
  still works when Windows has no IP or the display is black. On the reference
  host there is **no VNC rescue display**: the VirtIO video device is removed
  from the domain entirely (see Display stack), so SSH + QEMU Guest Agent are
  the rescue channels.
- The streaming display is an IDD virtual display (VDD) bound to the
  passed-through Intel Arc VF and is the VM's **only** display. This keeps
  Windows' `SetDisplayConfig` API healthy (Sunshine logs
  `API is available: true`) and removes the need for any display-mode
  switching. The `stream-mode.sh` / `stream-display-mode.ps1` helpers remain
  only as a fallback for hosts that keep a VirtIO video device.

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
│   ├── verify-stack.sh         # 15-point host-side acceptance check
│   └── guest/                  # PowerShell scripts deployed to C:\Admin\scripts
├── win11.xml / win11-vf.xml    # libvirt domain examples (edit to your host)
├── docs/vm-fidelity.md         # legitimate hardware-fidelity knobs
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
Reference result (2026-08-26, after the Sunshine scheduled-task/working-directory
fix): `PASS=14 FAIL=0`. The 6 GiB runtime-lean reference now reports
`PASS=15 FAIL=0`, including both Sunshine TCP endpoints. After removing the
VirtIO video device entirely (VDD-only display), Sunshine logs
`API is available: true` and no display-mode switching is needed.
Live Moonlight sessions at the reference target
`2560x1600@90` (200% desktop scaling) over the dedicated NIC complete cleanly
(HEVC QSV, `Session ended` + display-mode revert on disconnect, Sunshine stays
alive). The patched `qsv_async_depth` build is installed and runs with
`qsv_async_depth=1`; sustained high-content FPS numbers are left to real-world
use (see Known limitations).

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
| `stream-display-mode.ps1` | switch between streaming mode (`OnlyVdd`) and rescue mode (`RestoreBoth`); stops/restarts Sunshine around the display switch |
| `sunshine-display-prep.ps1` | automatic Sunshine connect/disconnect display switch; toggles only the VirtIO PnP device |
| `set-display-scaling.ps1` | set desktop scaling (default 200%) via registry |
| `install-vb-cable.ps1` | install the signed VB-CABLE virtual audio device |
| `set-display-extend.ps1` | keep VirtIO + VDD in extended mode |
| `set-headless-power.ps1` | disable monitor/sleep/hibernate timeouts |
| `disable-modal-prompts.ps1` | headless-VM hardening: auto-elevate UAC, disable SmartScreen and firewall first-run prompts |
| `setup-display-logontask.ps1` | re-apply topology at every logon (uses `fix-display-topology.ps1` when MultiMonitorTool is present) |
| `setup-sunshine-user-task.ps1` | register the `SunshineUser` scheduled task (interactive session, correct `WorkingDirectory`, optional wrapper) |
| `start-sunshine.ps1` | ordered boot wrapper: wait for VDD + Arc VF, restore VirtIO only on hosts that have it (reference host is VDD-only), then start Sunshine and verify both listeners |
| `setup-deadman.ps1` | scheduled VDD-disable fallback after changes |
| `display-rescue.ps1` | disable VDD + reboot (runs via QGA if needed) |
| `get-credentials-status.ps1` | audit where credentials live without printing them |
| `lean-runtime.ps1` | audit/apply/rollback runtime-service reductions for a video-only VM |
| `set-utf8.ps1` / `restore-utf8.ps1` | enable / roll back global UTF-8 |
| `enable-autologon.ps1` / `disable-autologon.ps1` | interactive-session AutoLogon |
| `install-ffmpeg.ps1` | deploy standalone FFmpeg (BtbN win64-gpl) to `C:\Admin\tools\ffmpeg` and run a QSV smoke test |
| `bench-qsv.ps1` | measure QSV encode throughput (resolution/fps/codec/preset/async-depth) |
| `animate-desktop.ps1` | WPF full-rate animation used to stress-test the capture→encode pipeline |
| `upgrade-intel-driver.ps1` | ordered Intel driver upgrade: stop Sunshine, disable VDD, install, reboot, recreate VDD with devcon, restart Sunshine |
| `build-sunshine-patched.ps1` / `.sh` | MSYS2 build of the `qsv_async_depth`-patched Sunshine (see `patches/`) |

Copy `drivers/MultiMonitorTool/MultiMonitorTool.exe` from the download step to
`C:\Admin\tools\MultiMonitorTool.exe` on the guest before running
`setup-display-logontask.ps1`. Copy the VB-CABLE driver files
(`drivers/VBCABLE/vbMmeCable64_win10.*`) to `C:\Admin\VBCABLE\` and run
`install-vb-cable.ps1` once to give Sunshine an audio endpoint.

### Runtime memory profile

`lean-runtime.ps1` changes selected service startup modes and, with explicit
flags, removes unused vendor/consumer startup entries, telemetry tasks and
consumer AppX packages. It never removes the WebView2 runtime, management
components or VirtIO/Intel/VDD drivers, and it refuses to apply if QGA, SSH,
SunshineUser or the three display adapters are not healthy. Run the audit first
from an elevated Windows PowerShell 5.1 session:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\lean-runtime.ps1 -Mode Audit
```

The conservative apply profile disables services with no role in this VM, such
as local search, printing, Bluetooth, UPnP, Maps, phone integration, Xbox and
Internet Connection Sharing. It saves the original service startup/state in
`C:\Admin\config\lean-runtime-services.json`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\lean-runtime.ps1 -Mode Apply
```

On the validated guest, Intel Driver & Support Assistant and Intel Graphics
Software are also unnecessary resident helpers. Add
`-DisableVendorStartup` to remove the Intel Graphics Software logon entry and
stop its overlay/PresentMon processes; the Intel display driver, Arc VF,
QuickSync and VDD remain installed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\lean-runtime.ps1 -Mode Apply -DisableVendorStartup
```

Use `-IncludeAggressive` only after measuring actual pressure. It additionally
targets Microsoft telemetry tasks, push notifications, OneDrive, Office/Outlook
and consumer per-user services. SysMain is intentionally not disabled on this
guest because enabling Windows Memory Compression restores that service; the
script keeps compression enabled instead. Add `-RemoveConsumerAppx` to
remove the explicit allowlist of Widgets/Web Experience, weather/news, Xbox,
Teams, Clipchamp and other consumer packages. AppX removal is recorded but is
not automatically reversible; the WebView2 runtime remains installed.
`Apply` and `Rollback` require an elevated Administrator PowerShell session.
Use `-DisableUnusedRemote` only when RDP and WinRM are not needed as fallback
channels. Apply the aggressive profile with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\lean-runtime.ps1 `
  -Mode Apply -IncludeAggressive -DisableConsumerStartup -RemoveConsumerAppx
```

Revert service/startup/task changes with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\lean-runtime.ps1 -Mode Rollback
```

Judge the result after a reboot and a real 30–60 minute Sunshine session, not
from the pre-reboot process list. Keep Windows Memory Compression and the
system-managed page file enabled; the script intentionally does not change
either.

## Display stack

- **VirtIO rescue display** (`Red Hat VirtIO GPU`): present in rescue mode,
  loopback VNC only, low-resolution fallback. **Removed on the reference
  host**: with any VirtIO display path in the Windows display database
  (active, disabled or stale), `SetDisplayConfig(SDC_VALIDATE |
  SDC_USE_DATABASE_CURRENT)` fails with `ERROR_GEN_FAILURE` on this Windows
  26H1 build, which breaks Sunshine's display management. The reference
  domain therefore uses `<video><model type='none'/></video>` and relies on
  SSH + QGA for rescue. `stream-mode.sh` exists for hosts that keep VirtIO.
- **VDD** (`ROOT\DISPLAY\0000`, Virtual-Display-Driver 25.7.23, IDD): one
  virtual monitor, 16:9 (up to 3840x2160) and 16:10 (up to 3200x2000) modes at
  30/60/90/120/144/165 Hz, bound to the guest-side PCI bus of the Intel VF
  (`Intel(R) Arc(TM) B390 GPU,6` on the reference host).
- **Sunshine**: `capture=ddx`, `encoder=quicksync`,
  `adapter_name=Intel(R) Arc(TM) B390 GPU`,
  `output_name=<VDD device_id GUID>`,
  `dd_configuration_option=ensure_only_display` (in streaming mode the VDD is
  already the only display, so this is a no-op topology-wise and only the
  client resolution/refresh is applied),
  `dd_resolution_option=auto`, `dd_refresh_rate_option=auto`,
  `dd_config_revert_on_disconnect=enabled`.
- **No mode switching on the reference host**: the VDD is the only display, so
  Sunshine's `ensure_only_display` is a topology no-op and only applies the
  client resolution/refresh. Verified end-to-end: `API is available: true`,
  `2560x1600@90` session, clean revert on disconnect.
- **Fallback for VirtIO hosts**: if you keep a VirtIO video device,
  `scripts/host/stream-mode.sh on|off` toggles VDD-only streaming vs rescue
  topology using `stream-display-mode.ps1` (PnP-disable VirtIO; stops/restarts
  Sunshine around the switch). Do not use it mid-session.
- **Sunshine launch**: it runs as the interactive `SunshineUser` scheduled
  task (AutoLogon is required for `ddx`). Sunshine resolves
  `assets/shaders/directx/*.hlsl` **relative to its working directory**, so
  the task must set `WorkingDirectory=C:\Program Files\Sunshine`. A task
  without it crashes at startup with `0xC0000005` after logging
  `Couldn't compile [...] 0x80070003` and `Platform failed to initialize`.
  `start-sunshine.ps1` additionally waits for VDD + Arc VF before launching,
  so boot order never depends on Task Scheduler luck.
- **Topology**: `DisplaySwitch.exe` alone can race and leave one display
  disconnected, which makes Sunshine fail with `Failed to locate an output
  device`. `fix-display-topology.ps1` uses MultiMonitorTool to deterministically
  enable both monitors, place VDD to the right of VirtIO and keep VirtIO
  primary.
- **Modes**: the VDD settings advertise 16:9 and 16:10 modes from 800x600 up to
  3840x2160 at 30/60/90/120/144/165 Hz. The reference target is
  **2560x1600 @ 90 Hz with 200% desktop scaling** (comfortable for a 16:10
  client and well within the Arc VF's QSV budget). 3200x2000 @ 165 Hz remains
  available but sits at the encoder's limit (see Known limitations). Sunshine
  applies the client resolution/refresh on connect (`dd_resolution_option=auto`,
  `dd_refresh_rate_option=auto`).
- **Audio**: the guest has **VB-CABLE** installed as its only audio device;
  Sunshine captures `F32 48000 2.0` from `CABLE Input`. The kernel-mode
  `Virtual Audio Driver` from the VDD project is **rejected by this Windows
  build** (`CM_PROB_UNSIGNED_DRIVER`, error 0xC0000428), so the signed
  VB-CABLE driver is used instead.
- **Headless power policy**: run `set-headless-power.ps1` once so Windows never
  turns off the VDD display or sleeps (a 5-minute display timeout makes the
  streamed desktop go black even though the VM is healthy).

### Encoding: H.264, HEVC or AV1?

The reference config uses:

```text
encoder = quicksync
av1_mode = 0     # advertise AV1 based on encoder capabilities (recommended)
hevc_mode = 0    # advertise HEVC based on encoder capabilities (recommended)
qsv_preset = medium
```

Sunshine's codec-mode values are: **0 = advertise based on encoder
capabilities (recommended), 1 = do not advertise, 2 = advertise 8-bit Main,
3 = additionally advertise 10-bit/HDR**. The reference config keeps the
recommended `0/0`, so Moonlight can negotiate H.264, HEVC or AV1 depending on
what the client asks for. The reference logs confirm all three Quick Sync
encoders are available on the Arc VF:

```text
Found H.264 encoder: h264_qsv [quicksync]
Found HEVC encoder:  hevc_qsv [quicksync]
Found AV1 encoder:   av1_qsv [quicksync]
```

For maximum efficiency on a network where both ends support it, ask the client
for AV1; HEVC is the best compatibility/efficiency middle ground; H.264 is the
fallback. Example client flags: `--video-codec AV1` / `HEVC` / `auto`.

Recommended client command (reference target, windowed):

```bash
# no mode switch needed on the reference host (VDD is the only display):
moonlight stream --resolution 2560x1600 --fps 90 \
  --display-mode windowed --bitrate 50000 --video-codec auto \
  192.168.200.2 Desktop
```

Hosts that keep a VirtIO video device should wrap the same command with
`scripts/host/stream-mode.sh on` / `... off` (see Display stack).

**Throughput caveat**: stock Sunshine hardcodes `async_depth=1` for every QSV
encoder (one frame in flight, lowest latency). On this Arc VF that caps the
whole pipeline at roughly 70-80 FPS at 3200x2000 even though the encoder alone
can do ~153 FPS. `patches/sunshine-qsv-async-depth.patch` adds a
`qsv_async_depth` config option (default 1) and `build-sunshine-patched.ps1`
rebuilds Sunshine with it. **Do not raise it blindly**: on the reference
machine `qsv_async_depth=4` made Sunshine hang on client disconnect
(`Fatal: Hang detected! Session failed to terminate in 10 seconds.`), so `1`
is the stable production value. If you experiment with 2/3, always verify a
real connect→disconnect cycle first. See
[Known limitations](#validation-scope-and-known-limitations) for measured
numbers.

### Optional: rebuild Sunshine with `qsv_async_depth`

Stock Sunshine works fine as shipped; rebuild only if you want to tune the
QSV async depth (or reproduce this repository's build). The reference machine
keeps `qsv_async_depth=1`, which behaves like stock:

1. Copy the patched source and patch to the guest (`C:\Admin\build\`), or let
   `build-sunshine-patched.sh` clone the official `v2026.516.143833` tag
   itself (it needs MSYS2 UCRT64 with the deps listed in the script).
2. Run `build-sunshine-patched.ps1` as Administrator on the guest. It installs
   MSYS2 on first run, applies `patches/sunshine-qsv-async-depth.patch`
   (including `SUNSHINE_SKIP_WIX=ON` and a system-Boost-1.91 compatibility
   tweak), builds, backs up `C:\Program Files\Sunshine`, swaps the build in and
   restarts the `SunshineUser` task.
3. Keep `qsv_async_depth = 1` (`configure-sunshine.ps1 -QsvAsyncDepth 1` does
   this), then restart the task. Raising it to 2-4 raises the throughput
   ceiling from ~80 FPS toward the encoder's ~153 FPS at 3200x2000, but on the
   reference machine 4 caused a teardown hang on client disconnect. Any
   experimental value must pass a real connect→disconnect test before
   production use.

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

**Sunshine crashes immediately (exit code `0xC0000005`), and the log ends
after `Trying encoder [quicksync]` with earlier
`Error: Couldn't compile [assets/shaders/directx/...hlsl] [0x80070003]` and
`Platform failed to initialize`.** The `SunshineUser` scheduled task is
running Sunshine without its assets directory as the working directory
(Task Scheduler defaults to `C:\Windows\System32`). Re-register the task with
`setup-sunshine-user-task.ps1` (it sets `WorkingDirectory=C:\Program Files\Sunshine`
and optionally routes through the ordered `start-sunshine.ps1` wrapper), then
restart the task. This was the root cause of the "QSV starts and instantly
crashes" symptom on the reference host.

**After an Intel driver upgrade the VDD monitor is gone or stuck in Error,
and `pnputil /enable-device "ROOT\DISPLAY\0000"` does not bring it back.**
Driver re-enumeration can leave the root device disabled/dropped. Recreate it
deterministically with devcon, then fix the topology and start Sunshine:

```powershell
C:\Admin\VDD\devcon.exe install C:\Admin\VDD\MttVDD.inf Root\MttVDD
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\fix-display-topology.ps1
Start-ScheduledTask -TaskName SunshineUser
```

The full ordered sequence (disable VDD → install → reboot → recreate → start)
is automated by `upgrade-intel-driver.ps1`, which registers a RunOnce
continuation so a driver upgrade is one command end-to-end.

**Moonlight pairs, the stream starts, but there is no video and Moonlight
suggests checking UDP 47998/48000.** The video stream is a new inbound UDP
flow from the guest to the host over the dedicated `sunshine-private` NIC
(`virbr1`). The host's `ufw` `DEFAULT_INPUT_POLICY="DROP"` silently drops it
(the audio probe passes only because it is an established-flow reply). Allow
it once on the host:

```bash
sudo ufw allow in on virbr1 to any port 47998:48010 proto udp
sudo ufw reload
```

Traffic split by design: SSH/Web UI/QGA use `192.168.122.50` (`default`);
Moonlight control + video/audio use `192.168.200.2` (`sunshine-private`).

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
| Sunshine patch | `patches/sunshine-qsv-async-depth.patch` (adds `qsv_async_depth`) |
| FFmpeg (guest) | BtbN `ffmpeg-master-latest-win64-gpl` (N-126264, QSV encoders verified) |
| OpenSSH (guest) | `9.8.3.0` (Win32-OpenSSH preview) |
| winget | `1.29.290` |
| Moonlight (host client) | `6.1.0` |
| Guest resources | 4 vCPU / 6 GiB / 256 GiB qcow2 |

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
- **Display API conflict (reference host)**: on Windows 26H1 build 28000.1,
  any VirtIO display path in the display database — active, PnP-disabled or
  stale — makes `SetDisplayConfig(SDC_VALIDATE | SDC_USE_DATABASE_CURRENT)`
  fail with `ERROR_GEN_FAILURE`, which breaks Sunshine/MultiMonitorTool
  topology management and shows an **empty secondary VDD** (the "picture but
  not operable" failure). The reference fix is **permanent**: the VirtIO video
  device is removed from the domain (`<video><model type='none'/>`) and its
  stale node is deleted from Windows. Consequence: **no VNC rescue display on
  the reference host**; rescue is SSH + QEMU Guest Agent. Hosts that keep
  VirtIO can use `stream-mode.sh on|off`, but must accept the mode-switch
  tradeoff.
- Intel display driver upgrades were validated once (`32.0.101.8356` →
  `32.0.101.8974`) using `upgrade-intel-driver.ps1`: disable VDD → install →
  reboot → recreate VDD with devcon → restart Sunshine. The recreate step is
  mandatory; `pnputil /enable-device` alone left the VDD in Error on this
  reference host.
- Stock Sunshine caps QSV at `async_depth=1`. Measured on the reference host
  at 3200x2000: encoder-only throughput is ~153 FPS (HEVC medium,
  `async_depth=4`), but the full capture→convert→encode pipeline sustains only
  ~70-80 FPS with the stock `async_depth=1`. The repository patch makes the
  depth configurable; the reference guest now runs the patched build with
  `qsv_async_depth = 1` (same behavior as stock) and a short connect→disconnect
  test ended cleanly (`Session ended`, process stayed alive). Raising the
  depth to 4 on this reference host caused Sunshine to hang on client
  disconnect (`Fatal: Hang detected! Session failed to terminate in
  10 seconds.`) and exit, so 2/3/4 remain experimental: verify a real
  connect→disconnect cycle before using them. We stopped short of a scripted
  full-rate stress benchmark, so treat the real-world sustained FPS as
  pipeline-limited (~70-80 FPS at depth 1) until you measure it in your own
  workload.
- The reference target is **2560x1600 @ 90 Hz with 200% desktop scaling**;
  it is comfortably within the Arc VF's QSV budget. 3200x2000 @ 165 Hz is at
  the edge of what the encoder can do (the encoder alone measured ~153 FPS at
  that resolution/preset with `async_depth=4`), so use it only if you accept a
  possible ceiling below 165 FPS or a lighter QSV preset.
- Desktop Duplication only delivers frames when the desktop content changes.
  An idle/static desktop therefore streams at a low frame rate by design
  (observed ~30-40 FPS at 3200x2000 with nothing moving); this is not a
  regression. Moving content, video or games drive the rate up to the
  pipeline/encoder ceiling.
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
- The 4C/6G/256G configuration is the validated setup, not a benchmark or a
  performance ceiling.
- `lean-runtime.ps1` can reduce runtime services, but the reference templates
  keep the validated **4 vCPU / 6 GiB / 256 GiB** configuration; treat a
  different memory size as your own unvalidated configuration.

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
- On the reference host there is no VNC rescue display (VirtIO video is
  removed); use SSH + QGA. Hosts with VirtIO keep VNC on `127.0.0.1` only.
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
QEMU Guest Agent（参考机已移除 VirtIO 视频设备，无 VNC 救援屏）。串流侧用
VDD 虚拟显示器绑定 Arc VF，Sunshine 用 Quick Sync 协商 H.264/HEVC/AV1（参考配置
`av1_mode = 0` / `hevc_mode = 0`，按编码器能力自动通告）。Sunshine 由 `SunshineUser` 交互式计划任务
启动，任务必须带 `WorkingDirectory=C:\Program Files\Sunshine`，否则 shader
编译路径失败并空指针崩溃；`start-sunshine.ps1` 会先等 VDD 和 Arc VF 就绪再
启动，避免开机顺序竞态。参考机把 VirtIO 视频设备从域中整体移除（VDD 是唯一
显示器）：这个 Windows 构建只要显示数据库里有 VirtIO 路径，`SetDisplayConfig`
就会返回 `ERROR_GEN_FAILURE`，导致串流只剩空副屏、看起来“不能操作”；移除后
API 恢复（Sunshine 日志 `API is available: true`），不再需要任何模式切换。
保留 VirtIO 的主机可用 `stream-mode.sh on|off` 做显式切换。仓库还带
`qsv_async_depth` 补丁（解除 Sunshine 写死
`async_depth=1` 造成的 3200×2000 下约 70-80 FPS 上限；但参考机生产值保持
`qsv_async_depth = 1`，调高到 4 会触发客户端断开时 Hang）与 guest 端
FFmpeg 工具链。
所有驱动、
安装包都不入库，通过 `scripts/download-assets.sh` 按 `assets.sha256`
下载；真实密码与 SSH 密钥由 `secrets.local.env` 等本地文件注入并被
gitignore。验收脚本 `verify-stack.sh` 共 15 项，参考机全绿。

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

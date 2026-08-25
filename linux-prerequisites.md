# Linux host prerequisites

Everything in this repository assumes a Linux host running libvirt/QEMU/KVM
with an Intel GPU that supports SR-IOV. This page is the complete host-side
checklist: QEMU/libvirt installation, VF creation and persistence, both
networks, firewall notes, storage and verification.

## Reference environment

| Component | Version / value |
| --- | --- |
| Distro | CachyOS (Arch-based), rolling |
| Kernel | `7.2.0-1-cachyos` |
| QEMU | `qemu-desktop 11.1.0-1` |
| libvirt | `1:12.6.0-1.1` (`libvirt 12.6.0`, API QEMU 12.6.0) |
| OVMF | `edk2-ovmf 202605-1` |
| virt-viewer | `11.0-4.1` |
| GPU | Intel Panther Lake integrated graphics: Arc B390 (`8086:b080`) |
| GPU driver | `xe` |
| VF passed to guest | `0000:00:02.1` |
| VF persistence | systemd oneshot `b390-sriov.service` |
| Firewall | `ufw` installed and enabled |
| Guest OS | Windows 11 Pro 26H1, build `28000.1` |
| Guest resources | 4 vCPU / 8 GiB / 256 GiB disk |
| Moonlight (host client) | `6.1.0` |

> Intel's GFX SR-IOV Toolkit officially lists Ubuntu 24.04.4 + kernel 6.18 in
> its validation matrix. CachyOS is not in that matrix, but the same workflow
> works here. Treat kernel upgrades and VF reset issues as a separate
> troubleshooting track from the Windows display topology.
>
> Validation scope: every command in this playbook was tested on the exact
> reference environment above and on **no other** host/kernel/GPU combination.
> Adjust the PCI BDF, driver name, VF count and network MACs to your hardware,
> and re-run `scripts/host/check-host.sh` before assuming it works.

## 1. Install QEMU and libvirt

Arch-based (reference host):

```bash
sudo pacman -S --needed \
  qemu-desktop \
  libvirt \
  edk2-ovmf \
  virt-viewer \
  dnsmasq \
  iptables-nft \
  xorriso \
  imagemagick \
  openssh \
  curl \
  openbsd-netcat
```

- `qemu-desktop` provides `qemu-system-x86_64`, `qemu-img` and the QEMU tools.
  `qemu-full` additionally bundles audio/display extras; it is fine too.
- `edk2-ovmf` provides UEFI firmware for the VM.
- `openbsd-netcat` is used by the preflight/verify scripts for port checks.

Debian/Ubuntu equivalents:

```bash
sudo apt install -y \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients \
  ovmf virt-viewer \
  dnsmasq-base iptables \
  xorriso imagemagick openssh-client curl netcat-openbsd
```

## 2. Enable services and user groups

libvirt on Arch uses socket activation for its logging/lock daemons, so enable
the sockets (not only the legacy services):

```bash
sudo systemctl enable --now libvirtd virtlogd.socket virtlockd.socket
sudo usermod -aG libvirt,kvm "$USER"
```

Log out and back in (or `newgrp libvirt`) for group changes to take effect.
Verify:

```bash
virsh version
ls -l /dev/kvm
systemctl is-active libvirtd virtlogd.socket virtlockd.socket
virsh -c qemu:///system list --all
```

## 3. IOMMU

Enable IOMMU in the kernel command line if not already active:

```bash
# bootloader / kernel cmdline, then reboot
intel_iommu=on iommu=pt
```

Verification (no root needed):

```bash
ls /sys/kernel/iommu_groups | wc -l   # reference host: 26
```

## 4. SR-IOV VF: conditions and configuration

### Conditions checklist

- The PF is owned by the GPU driver: `xe` on newer Arc/Panther Lake, `i915` on
  older iGPU SR-IOV setups.
- IOMMU is active (step 3).
- The PF reports enough VFs: `sriov_totalvfs >= 1`.
- VFs are created **unbound**: set `sriov_drivers_autoprobe = 0` **before**
  writing `sriov_numvfs`, otherwise the kernel may bind a VF to a random
  driver before libvirt can attach it.
- The libvirt domain uses `<hostdev mode='subsystem' type='pci'
  managed='yes'>` so libvirt binds the VF to `xe-vfio-pci` / `vfio-pci` at VM
  start.

### One-shot manual creation

```bash
PF=0000:00:02.0
echo 0 | sudo tee /sys/bus/pci/devices/$PF/sriov_drivers_autoprobe
echo 1 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs
lspci -nnk -d 8086:
```

Expected after the VM starts:

```text
00:02.1 VGA compatible controller [0300]: Intel Corporation Panther Lake [Arc B390] [8086:b080] (rev 04)
	Kernel driver in use: xe-vfio-pci
```

### Persist across boots with systemd

Use the helper scripts in `scripts/host/`:

```bash
sudo scripts/host/install-sriov-service.sh 0000:00:02.0 1
systemctl status intel-sriov-vf.service
```

This installs `/usr/local/sbin/intel-sriov-vf-create` plus
`/etc/systemd/system/intel-sriov-vf.service`, and enables it. The creator
script performs the same safety checks as the reference host's service:

- refuses to run if the PF is not on `xe`/`i915`;
- skips when the requested VF count already exists;
- refuses to touch unexpected VF counts;
- disables `sriov_drivers_autoprobe` before creating VFs;
- verifies every VF appeared and stayed unbound;
- double-checks the PF driver afterwards.

The reference host used `WantedBy=graphical.target`; the template uses
`multi-user.target` so it also works on headless servers.

### Preflight check

```bash
bash scripts/host/check-host.sh
```

The checker is read-only and covers binaries, KVM, libvirt services, IOMMU,
PF driver, VF count/binding, the SR-IOV systemd unit, both networks and guest
reachability.

## 5. Two networks

The playbook uses **two** libvirt networks:

| Network | Bridge | Subnet | Purpose |
| --- | --- | --- | --- |
| `default` | `virbr0` | `192.168.122.0/24` | NAT, management: SSH, Web UI, QGA, DHCP reservation |
| `sunshine-private` | `virbr1` | `192.168.200.0/24` | **dedicated Moonlight streaming link** (isolated, no internet) |

Templates: [config/libvirt/default-network.example.xml](config/libvirt/default-network.example.xml)
and [config/libvirt/sunshine-private.example.xml](config/libvirt/sunshine-private.example.xml).

```bash
sudo virsh -c qemu:///system net-define config/libvirt/default-network.example.xml
sudo virsh -c qemu:///system net-define config/libvirt/sunshine-private.example.xml
sudo virsh -c qemu:///system net-start default
sudo virsh -c qemu:///system net-start sunshine-private
sudo virsh -c qemu:///system net-autostart default
sudo virsh -c qemu:///system net-autostart sunshine-private
```

Important:

- `default` uses a DHCP reservation so the guest always gets
  `192.168.122.50`. Replace the example MAC with the **actual MAC of your
  guest's first NIC** (libvirt generates one when you first define the domain).
- `sunshine-private` is isolated (no forwarding, no DHCP). The guest configures
  its second NIC statically as `192.168.200.2/24` with
  `scripts/guest/set-private-nic.ps1`; the host side is `192.168.200.1`.
- Traffic split: SSH/Web UI/QGA go over `default` (`192.168.122.50`); Moonlight
  control and video/audio go over `sunshine-private` (`192.168.200.2`). The
  dedicated link is not for general internet traffic.
- Add a convenient hostname on the host:

  ```text
  192.168.122.50 win-dev
  ```

## 6. Host firewall (ufw)

The reference host has **ufw installed and enabled**
(`ENABLED=yes` in `/etc/ufw/ufw.conf`) with
`DEFAULT_FORWARD_POLICY="DROP"` and `DEFAULT_INPUT_POLICY="DROP"`.

For **Moonlight from the Linux host itself** (the common case in this
playbook), one host rule is required. The video stream is a **new inbound UDP
flow from the guest to the host** on `virbr1`; with
`DEFAULT_INPUT_POLICY="DROP"` it is silently dropped even though the Windows
guest firewall allows it (the audio probe appears to pass because it is a
reply to an established flow). Add:

```bash
sudo ufw allow in on virbr1 to any port 47998:48010 proto udp
sudo ufw reload
```

The Windows guest rules for `47984-48010` (TCP/UDP) are configured by
`scripts/guest/setup-sunshine.ps1` and verified with `Get-NetFirewallRule`.

Additional scenarios:

```bash
# 1) Guest needs Internet through libvirt NAT:
#    change DEFAULT_FORWARD_POLICY to ACCEPT, then allow forwarding on virbr0
sudo sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw allow in on virbr0
sudo ufw allow out on virbr0
sudo ufw route allow in on virbr0
sudo ufw reload

# 2) Remote Moonlight clients reach the host from the LAN (host as gateway):
sudo ufw allow 47984:48010/tcp
sudo ufw allow 47998:48010/udp
# then DNAT 47984-48010 on the host to 192.168.200.2 (or use a bridged NIC)
```

If you change ufw policy, verify the guest still reaches the host and that
`virsh net-list` networks remain active. libvirt and ufw both manipulate
iptables/nftables; keep the changes above explicit instead of disabling the
firewall.

## 6.1 Known host pitfalls

### OpenSSH refuses to start: `Bad owner or permissions on ...ssh_config.d...`

OpenSSH requires system config files under `/etc/ssh/` to be owned by
`root`. If you see this error when running `ssh win-dev`:

```text
Bad owner or permissions on /etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf
```

check ownership first:

```bash
ls -l /etc/ssh/ssh_config.d/
```

On a healthy host these are `root:root` and plain `ssh win-dev` works. If they
are owned by another user (often after container/sandbox file remapping or a
bad package extraction):

```bash
sudo chown -h root:root /etc/ssh/ssh_config.d/*
```

Until it is fixed, `ssh -F ~/.ssh/config win-dev` bypasses the system config
and works as a temporary workaround.

### Persistent XML changes require a cold restart

`virsh reboot win11` only reboots the guest OS; the running QEMU device model
stays unchanged. After editing the persistent domain XML (for example removing
install ISO drives), use `virsh shutdown win11` and then `virsh start win11`.
Verify with `virsh domblklist win11` / `domiflist win11`.

## 7. Storage

Keep images on a fast, stable filesystem — never `/tmp`. On the reference host
the pool lives under `/run/media/<user>/TiPro9000/libvirt/win11/`.

```bash
# 256 GiB disk for the guest
qemu-img create -f qcow2 win11.qcow2 256G
```

## 8. Host-side tooling used by the playbook

`scripts/verify-stack.sh` expects `virsh`, `ssh`, `scp`, `identify`
(ImageMagick) and `nc` (for port checks). `scripts/host/check-host.sh` is the
pre-deployment twin of that script.

The guest itself only needs network access during installation if you choose
the online fallback path; the offline path ships OpenSSH MSI, winget bundles,
drivers and Sunshine on media prepared by `scripts/download-assets.sh`.

## 9. Optional but recommended

- A local VNC/SPICE viewer (`virt-viewer`) for the rescue display.
- `guestfs-tools` if you want to inspect/modify the qcow2 image offline.
- A Moonlight client (Linux/Windows/Android/iOS) on the streaming side.

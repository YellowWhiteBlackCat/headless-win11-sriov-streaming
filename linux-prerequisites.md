# Linux host prerequisites

Everything in this repository assumes a Linux host running libvirt/QEMU/KVM
with an Intel GPU that supports SR-IOV. This page documents the exact
prerequisites and the reference environment the playbook was validated on.

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
| VF passed to guest | `0000:00:02.1` bound to `xe-vfio-pci` |
| Guest | Windows 11 (64-bit), 4 vCPU / 8 GiB / 256 GiB disk |

> Intel's GFX SR-IOV Toolkit officially lists Ubuntu 24.04.4 + kernel 6.18 in
> its validation matrix. CachyOS is not in that matrix, but the same workflow
> works here. Treat kernel upgrades and VF reset issues as a separate
> troubleshooting track from the Windows display topology.

## 1. Packages

On Arch-based systems:

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
  curl
```

Debian/Ubuntu equivalents:

```bash
sudo apt install -y \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients \
  ovmf virt-viewer \
  dnsmasq-base iptables \
  genisoimage/xorriso \
  imagemagick openssh-client curl
```

## 2. Services and user groups

```bash
sudo systemctl enable --now libvirtd virtlogd
sudo usermod -aG libvirt,kvm "$USER"
```

Log out and back in (or use `newgrp libvirt`) for the group change to take
effect. Verify:

```bash
virsh version
ls -l /dev/kvm
virsh -c qemu:///system list --all
```

## 3. IOMMU and Intel SR-IOV

Enable IOMMU if it is not already active:

```bash
# add to your bootloader/kernel command line, then reboot
intel_iommu=on iommu=pt
```

Verify:

```bash
dmesg | grep -i -E 'DMAR|IOMMU' | head
```

The `xe` kernel driver (used by newer Intel Arc/Panther Lake GPUs) creates one
Virtual Function per `sriov_numvfs` entry:

```bash
# reference host: 1 VF for Arc B390
echo 1 | sudo tee /sys/bus/pci/devices/0000:00:02.0/sriov_numvfs
lspci -nnk -d 8086:
```

The VF should appear as `0000:00:02.1` and be automatically bound to
`xe-vfio-pci` for passthrough:

```text
00:02.1 VGA compatible controller [0300]: Intel Corporation Panther Lake [Arc B390] [8086:b080] (rev 04)
	Kernel driver in use: xe-vfio-pci
```

Persist the VF count with your distro's mechanism (e.g. a systemd service,
udev rule, or kernel parameter such as `xe.max_vfs=1` if your driver exposes
it). Adjust the PCI BDF in the libvirt domain XML to match your host.

## 4. libvirt networking

The default NAT network (`192.168.122.0/24`) is sufficient. For a stable guest
address, reserve the MAC → IP mapping:

```bash
virsh -c qemu:///system net-edit default
```

Example reservation:

```xml
<dhcp>
  <range start='192.168.122.2' end='192.168.122.254'/>
  <host mac='52:54:00:30:cb:92' ip='192.168.122.50'/>
</dhcp>
```

Then:

```bash
virsh -c qemu:///system net-destroy default
virsh -c qemu:///system net-start default
```

For convenience add the host to `/etc/hosts`:

```text
192.168.122.50 win-dev
```

## 5. Storage

Keep images on a fast, stable filesystem — never `/tmp`. On the reference host
the pool lives under `/run/media/<user>/TiPro9000/libvirt/win11/`.

```bash
# 256 GiB disk for the guest
qemu-img create -f qcow2 win11.qcow2 256G
```

## 6. Host-side tooling used by the verification script

`scripts/verify-stack.sh` expects:

- `virsh` (libvirt client)
- `ssh` / `scp` with key-based auth to the guest (`win-dev`)
- ImageMagick's `identify` (VNC screenshot sanity check)
- `qemu-img`

The guest itself only needs network access during installation if you choose
the online fallback path; the offline path ships OpenSSH MSI, winget bundles,
drivers and Sunshine on media prepared by `scripts/download-assets.sh`.

## 7. Optional but recommended

- A local VNC/SPICE viewer (`virt-viewer`) for the rescue display.
- `guestfs-tools` if you want to inspect/modify the qcow2 image offline.
- A Moonlight client (Windows/Linux/Android/iOS) on the streaming side.

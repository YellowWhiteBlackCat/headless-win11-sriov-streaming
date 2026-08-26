# VM hardware fidelity and performance knobs

This document records the QEMU/KVM configuration choices that give the Windows
guest a hardware environment as complete as a normal development PC.

## 1. Baseline already present in `win11-vf.xml`

| Area | Configuration | Why |
| --- | --- | --- |
| Machine | `pc-q35-11.1` | Modern PCIe PC platform instead of legacy i440FX |
| CPU | `host-passthrough`, `1 socket / 4 cores / 1 thread`, pinned vCPU 4-7 | Full host feature set; host has no SMT so 4c/1t is the honest topology |
| Firmware | OVMF (`OVMF_CODE.secboot.4m.fd`) + per-VM `win11_VARS.fd` | Real UEFI variable storage; each VM gets its own copy |
| TPM | `tpm-crb` + `swtpm` 2.0 emulator | Realistic TPM 2.0 for Windows 11 |
| Disk | virtio-blk, qcow2, `cache=none`, `discard=unmap` | Fast, standard VirtIO storage |
| Network | 2x virtio-net (management + private streaming) | Fast VirtIO NICs |
| Input | qemu-xhci + usb-tablet + PS/2 keyboard/mouse | Complete, usable input set |
| Paravirt | Hyper-V enlightenments (`relaxed`, `vapic`, `spinlocks`, `vpindex`, `runtime`, `synic`, `stimer`, `frequencies`, `tlbflush`, `ipi`, `evmcs`, `avic`) + `hypervclock` | Standard Windows guest acceleration |
| Other | `smm on`, `vmport off`, `hpet off` | Firmware fidelity / reduced backdoor surface |
| Memory | 6 GiB memfd shared | Operator-specified stable size |

## 2. Added in this pass

| Knob | Effect |
| --- | --- |
| `<kvm><hint-dedicated state='on'/></kvm>` | Tells Windows that vCPUs are dedicated, improving spinlock/latency behavior; safe because vCPUs are pinned |
| `<msrs unknown='ignore'/>` | Lets Windows boot/run even when it probes model-specific registers QEMU does not model |
| `<hyperv><reset state='on'/></hyperv>` | Enables the Hyper-V reset interface used by Windows during reboot, making restarts more reliable |

These only take effect after the domain is restarted. Verify afterwards with
`scripts/verify-stack.sh` (SSH, QEMU Guest Agent, Sunshine listeners, displays).

## 3. Expected effects

These changes improve guest scheduling, reboot robustness and MSR tolerance.

## 4. Stability notes

- Keep the validated **4 vCPU / 6 GiB / 256 GiB** allocation; changing memory
  or topology is an unvalidated configuration.
- The host (Intel Core Ultra X7 358H) exposes no SMT, so `4 cores / 1 thread`
  is correct; do not set `threads=2` just because a generic guide suggests it.
- `migratable='on'` is kept deliberately: this VM is not migrated, and flipping
  it off buys almost nothing while widening the feature surface.
- Any change to the PCI topology can shift the guest-side bus number of the
  Intel Arc VF and invalidate `vdd_settings.xml` (see
  `config/vdd_settings.arc-b390.xml`).

## 5. 中文摘要

本文件记录的是**正经的开发环境硬件保真优化**：Q35、host-passthrough CPU、
OVMF 独立 NVRAM、swtpm 2.0、VirtIO 磁盘/网卡、Hyper-V 半虚拟化。本次新增
`hint-dedicated`、`msrs unknown=ignore`、Hyper-V `reset` 三项。

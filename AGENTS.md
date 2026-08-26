# Repository Guidelines

## Project Structure & Module Organization

This repository is a deployment playbook for a headless Windows 11 VM on
Linux/libvirt/QEMU/KVM with Intel Arc SR-IOV and Sunshine/Moonlight.

- Root XML, `.ps1`, `.cmd`, and `.sh` files define unattended setup, VM
  examples, ISO creation, and asset fetching.
- `scripts/host/` contains Linux preflight, SR-IOV service, and local-manual
  helpers; `scripts/guest/` contains PowerShell operations copied to
  `C:\Admin\scripts`.
- `config/` holds safe VDD/libvirt/network templates, `apps/manifest.json`
  defines guest applications, and `patches/` holds the Sunshine patch.
- `drivers/`, `apps/winget/`, `.build/`, and `logs/` are downloaded or runtime
  data. Keep generated ISOs, VM disks, screenshots, binaries, and logs out of
  commits.

## Build, Test, and Development Commands

- `scripts/download-assets.sh [--with-virtio]` downloads and verifies pinned
  assets using `assets.sha256`.
- `./build-iso.sh` builds `windows-bootstrap.iso`; it requires local secrets
  and an SSH public key.
- `bash scripts/host/check-host.sh` runs the read-only host/KVM/IOMMU/SR-IOV
  preflight.
- `scripts/verify-stack.sh` performs end-to-end VM acceptance checks. Override
  machine values with variables such as `DOM`, `SSH_HOST`, and `EXPECTED_IP`.
- `python3 scripts/host/gen-local-manual.py` generates the local,
  secret-bearing maintenance manual; never upload its output.

For a deployment, follow `README.md`: create the disk, define/start the domain
with `virsh`, attach Windows/VirtIO/bootstrap media, then run verification.

## Coding Style & Naming Conventions

Use Bash with the existing shebangs, quoted variables, small functions, and
explicit error handling. Preserve each script’s established `set` behavior.
Use four-space indentation in Bash, PowerShell, and Python. PowerShell files
use descriptive `Verb-Noun` functions/parameters; shell files use lowercase
kebab-case names. Keep Python PEP 8-compatible and type-annotated where
practical. Run `bash -n path/to/script.sh` after shell changes.

## Testing Guidelines

There is no separate unit-test suite or coverage gate. Run the host preflight
before deployment and after host reboots; treat `verify-stack.sh` output of
`FAIL=0` as the integration requirement. For guest-script changes, also run
the relevant `guest-verify.ps1` or `verify-apps.ps1` through SSH/QEMU Guest
Agent and record the environment-specific result.

## Security & Configuration

Start from `secrets.local.env.example` and `config/*example*`; never commit
passwords, private keys, local secret JSON, downloaded binaries, or real
machine-specific credentials. Review `CREDENTIALS.md` when changing bootstrap,
AutoLogon, SSH, or Sunshine authentication behavior.

## Commit & Pull Request Guidelines

Recent commits use short, imperative, sentence-case subjects such as `Fix ...`,
`Add ...`, and `Harden ...`, without a required prefix. Keep commits focused.
Pull requests should explain the affected host/guest workflow, list validation
commands and results, note hardware/version assumptions, and include a
screenshot only when display/VNC behavior is relevant. Do not attach secrets or
generated artifacts.

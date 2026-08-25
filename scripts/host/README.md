# Host-side helpers

- `check-host.sh` — read-only preflight: binaries, KVM/libvirt, IOMMU, GPU PF,
  VF count/driver, SR-IOV systemd service, both libvirt networks, and guest
  reachability. Run it before deployment and after every reboot:

  ```bash
  bash scripts/host/check-host.sh
  ```

- `sriov-vf-create.sh` — creates N unbound VFs on an Intel GPU PF with safety
  checks (PF driver, unexpected VF counts, VF must not be auto-bound).

- `sriov-vf.service` — systemd oneshot template. It is rendered by
  `install-sriov-service.sh`; `@PF@` and `@VF_COUNT@` are placeholders.

- `install-sriov-service.sh` — installs the creator + unit and enables it so
  the VFs exist after every boot:

  ```bash
  sudo scripts/host/install-sriov-service.sh 0000:00:02.0 1
  ```

- `gen-local-manual.py` — one-command generator for the local, secret-bearing
  maintenance manual (real passwords + live host/guest state). Writes
  `win11-vm-manual.md` (mode 0600) to the user's download directory:

  ```bash
  python3 scripts/host/gen-local-manual.py
  ```

- Network XML templates live in `config/libvirt/` (see the main prerequisites
  document for `virsh net-define` usage).

#!/usr/bin/env bash
#
# Read-only preflight check for the Linux host before deploying the Windows VM.
# No system state is modified. Override values with environment variables:
#   PF=0000:00:02.0 VF_COUNT=1 DOM=win11 SSH_HOST=win-dev

set -u

PF="${PF:-0000:00:02.0}"
VF_COUNT="${VF_COUNT:-1}"
DOM="${DOM:-win11}"
SSH_HOST="${SSH_HOST:-win-dev}"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "===== 1. Required binaries ====="
for bin in virsh qemu-img ssh scp identify curl; do
    if command -v "$bin" >/dev/null 2>&1; then
        pass "$bin found"
    else
        fail "$bin missing"
    fi
done

echo "===== 2. KVM / libvirt ====="
if [ -e /dev/kvm ]; then pass "/dev/kvm exists"; else fail "/dev/kvm missing"; fi
if systemctl is-active --quiet libvirtd; then pass "libvirtd active"; else fail "libvirtd not active"; fi
if systemctl is-enabled --quiet libvirtd; then pass "libvirtd enabled"; else fail "libvirtd not enabled"; fi
if systemctl is-active --quiet virtlogd.socket; then pass "virtlogd.socket active"; else fail "virtlogd.socket not active"; fi
if systemctl is-enabled --quiet virtlogd.socket; then pass "virtlogd.socket enabled"; else fail "virtlogd.socket not enabled"; fi

echo "===== 3. IOMMU ====="
groups=$(ls /sys/kernel/iommu_groups 2>/dev/null | wc -l)
if [ "${groups:-0}" -gt 0 ]; then pass "IOMMU groups present ($groups)"; else fail "IOMMU groups missing (enable intel_iommu=on iommu=pt)"; fi

echo "===== 4. GPU PF and SR-IOV capability ====="
pfdir="/sys/bus/pci/devices/$PF"
if [ -d "$pfdir" ]; then
    pass "PF $PF exists"
    driver=$(basename "$(readlink -f "$pfdir/driver" 2>/dev/null || true)" 2>/dev/null || echo none)
    if [ "$driver" = xe ] || [ "$driver" = i915 ]; then
        pass "PF driver=$driver"
    else
        fail "PF driver=$driver (expected xe or i915)"
    fi
    total=$(cat "$pfdir/sriov_totalvfs" 2>/dev/null || echo 0)
    if [ "$total" -ge "$VF_COUNT" ]; then
        pass "sriov_totalvfs=$total >= VF_COUNT=$VF_COUNT"
    else
        fail "sriov_totalvfs=$total < VF_COUNT=$VF_COUNT"
    fi
    current=$(cat "$pfdir/sriov_numvfs" 2>/dev/null || echo 0)
    if [ "$current" -eq "$VF_COUNT" ]; then
        pass "sriov_numvfs=$current"
    else
        fail "sriov_numvfs=$current (expected $VF_COUNT; check intel-sriov-vf.service)"
    fi
    for i in $(seq 0 $((VF_COUNT - 1))); do
        if [ -L "$pfdir/virtfn$i" ]; then
            vf=$(basename "$(readlink -f "$pfdir/virtfn$i")")
            if [ -L "/sys/bus/pci/devices/$vf/driver" ]; then
                vfdriver=$(basename "$(readlink -f "/sys/bus/pci/devices/$vf/driver")")
                case "$vfdriver" in
                    xe-vfio-pci|vfio-pci) pass "VF$i $vf bound to $vfdriver" ;;
                    *) fail "VF$i $vf bound to unexpected driver $vfdriver" ;;
                esac
            else
                pass "VF$i $vf present and unbound (libvirt will attach it)"
            fi
        else
            fail "virtfn$i missing on $PF"
        fi
    done
else
    fail "PF $PF not found (check lspci -nnk -d 8086:)"
fi

echo "===== 5. SR-IOV systemd service ====="
if systemctl list-unit-files | grep -q 'intel-sriov-vf.service'; then
    if systemctl is-enabled --quiet intel-sriov-vf.service; then
        pass "intel-sriov-vf.service enabled"
    else
        fail "intel-sriov-vf.service not enabled"
    fi
else
    # Reference host keeps its own service name; do not hard-fail on it.
    if systemctl list-unit-files | grep -q 'sriov.service'; then
        pass "SR-IOV service present (non-standard name)"
    else
        fail "no SR-IOV systemd service found"
    fi
fi

echo "===== 6. libvirt networks ====="
for net in default sunshine-private; do
    active=$(virsh -c qemu:///system net-info "$net" 2>/dev/null | awk '/^Active:/{print $2}' || true)
    if [ "$active" = yes ]; then
        pass "$net active"
    else
        fail "$net active=$active"
    fi
    autostart=$(virsh -c qemu:///system net-info "$net" 2>/dev/null | awk '/^Autostart:/{print $2}' || true)
    if [ "$autostart" = yes ]; then
        pass "$net autostart=yes"
    else
        fail "$net autostart=$autostart"
    fi
done

echo "===== 7. Guest reachability ====="
# Windows guests commonly block ICMP echo; TCP reachability is the real check.
if nc -zvw 3 192.168.200.2 47989 >/dev/null 2>&1; then
    pass "Sunshine TCP 47989 reachable (dedicated streaming NIC)"
else
    fail "Sunshine TCP 47989 unreachable on 192.168.200.2"
fi
if nc -zvw 3 192.168.122.50 47989 >/dev/null 2>&1; then
    pass "Sunshine TCP 47989 reachable (management NIC)"
else
    fail "Sunshine TCP 47989 unreachable on 192.168.122.50"
fi
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" hostname >/dev/null 2>&1; then
    pass "SSH $SSH_HOST"
else
    fail "SSH $SSH_HOST"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

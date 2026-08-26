#!/bin/sh
set -eu

# Create unbound SR-IOV Virtual Functions for an Intel GPU.
#
# Reference: Intel Arc B390 (Panther Lake) on the xe driver.
# Older iGPU SR-IOV setups use i915; override EXPECTED_DRIVER accordingly.
#
# Usage: sriov-vf-create.sh [PF] [VF_COUNT]

PF="${1:-0000:00:02.0}"
VF_COUNT="${2:-2}"
DEV="/sys/bus/pci/devices/$PF"
EXPECTED_DRIVER="${EXPECTED_DRIVER:-xe}"

if [ ! -d "$DEV" ]; then
    echo "SR-IOV: PCI device $PF not found" >&2
    exit 1
fi

# The PF must already be owned by the expected GPU driver. Never create VFs
# while the device is bound to something else (e.g. vfio-pci).
if [ "$(readlink -f "$DEV/driver" 2>/dev/null || true)" != "/sys/bus/pci/drivers/$EXPECTED_DRIVER" ]; then
    echo "SR-IOV: PF $PF is not using $EXPECTED_DRIVER; refusing to create VFs" >&2
    exit 1
fi

CURRENT="$(cat "$DEV/sriov_numvfs" 2>/dev/null || echo missing)"
if [ "$CURRENT" = "$VF_COUNT" ]; then
    echo "SR-IOV: $PF already has $VF_COUNT VF(s)"
    exit 0
fi

if [ "$CURRENT" != "0" ]; then
    echo "SR-IOV: unexpected existing VF count: $CURRENT" >&2
    exit 1
fi

# Order matters: stop the host from auto-probing the new VFs first, otherwise
# the kernel may bind them to a random driver before libvirt can attach them.
echo 0 > "$DEV/sriov_drivers_autoprobe"
echo "$VF_COUNT" > "$DEV/sriov_numvfs"

sleep 1

# Verify every VF appeared and is still unbound.
for i in $(seq 0 $((VF_COUNT - 1))); do
    if [ ! -L "$DEV/virtfn$i" ]; then
        echo "SR-IOV: virtfn$i did not appear on $PF" >&2
        echo 0 > "$DEV/sriov_numvfs"
        exit 1
    fi
    VF="$(basename "$(readlink -f "$DEV/virtfn$i")")"
    VFDEV="/sys/bus/pci/devices/$VF"
    if [ -L "$VFDEV/driver" ]; then
        DRIVER="$(basename "$(readlink -f "$VFDEV/driver")")"
        echo "SR-IOV: ERROR: $VF unexpectedly bound to $DRIVER" >&2
        echo 0 > "$DEV/sriov_numvfs"
        exit 1
    fi
    echo "SR-IOV: $VF created and left unbound"
done

# Double-check the PF was not disturbed.
if [ "$(readlink -f "$DEV/driver")" != "/sys/bus/pci/drivers/$EXPECTED_DRIVER" ]; then
    echo "SR-IOV: ERROR: PF $PF driver changed" >&2
    echo 0 > "$DEV/sriov_numvfs"
    exit 1
fi

echo "SR-IOV: $PF now has $VF_COUNT unbound VF(s)"

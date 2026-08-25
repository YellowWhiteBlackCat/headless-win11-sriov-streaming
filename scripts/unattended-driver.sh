#!/usr/bin/env bash
# Drives the only two interactive points of a KVM unattended Windows install:
#   1. OVMF "Press any key to boot from CD or DVD"          -> KEY_SPACE
#   2. Windows Setup "Where do you want to install Windows?" -> DOWN DOWN ENTER
# Run this right after `virsh start` on a blank disk. It exits once both
# interactions are done; the rest of Setup is fully automatic.
set -uo pipefail

DOM="${1:-win11}"
SHOT="/tmp/win11-unattended-check.png"
KEY_PRESSED=0
DISK_CLICKED=0

for i in $(seq 1 300); do
    if ! virsh -c qemu:///system screenshot "$DOM" "$SHOT" >/dev/null 2>&1; then
        sleep 2
        continue
    fi
    TEXT="$(TESSDATA_PREFIX=/tmp/tessdata tesseract "$SHOT" stdout -l chi_sim+eng 2>/dev/null)"

    if [ "$KEY_PRESSED" -eq 0 ] && printf '%s' "$TEXT" | grep -qi "Press any key"; then
        echo "[$(date +%H:%M:%S)] boot prompt detected; sending KEY_SPACE"
        virsh -c qemu:///system send-key "$DOM" KEY_SPACE
        KEY_PRESSED=1
    fi

    if [ "$DISK_CLICKED" -eq 0 ] &&
       { printf '%s' "$TEXT" | grep -qi "选择安装" ||
         printf '%s' "$TEXT" | grep -qi "where do you want to install"; }; then
        echo "[$(date +%H:%M:%S)] disk-selection screen detected; sending DOWN DOWN ENTER"
        virsh -c qemu:///system send-key "$DOM" KEY_DOWN KEY_DOWN KEY_ENTER
        DISK_CLICKED=1
    fi

    if [ "$KEY_PRESSED" -eq 1 ] && [ "$DISK_CLICKED" -eq 1 ]; then
        echo "[$(date +%H:%M:%S)] both interactions done; handoff to unattended Setup"
        exit 0
    fi
    sleep 2
done

echo "[$(date +%H:%M:%S)] timed out waiting for unattended interactions" >&2
exit 1

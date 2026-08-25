#!/usr/bin/env bash
# Presses KEY_SPACE once when OVMF shows "Press any key to boot from CD or DVD".
# Intended ONLY for the very first boot of a blank disk; run it right after
# `virsh start`, and let it exit after the first keypress (or timeout).
set -uo pipefail

DOM="${1:-win11}"
SHOT="/tmp/win11-bootcheck.png"

for i in $(seq 1 60); do
    if ! virsh -c qemu:///system screenshot "$DOM" "$SHOT" >/dev/null 2>&1; then
        sleep 2
        continue
    fi
    if tesseract "$SHOT" stdout -l eng 2>/dev/null | grep -qi "Press any key"; then
        echo "[$(date +%H:%M:%S)] prompt detected at attempt $i; sending KEY_SPACE"
        virsh -c qemu:///system send-key "$DOM" KEY_SPACE
        exit 0
    fi
    sleep 2
done

echo "[$(date +%H:%M:%S)] prompt not detected after 120s" >&2
exit 1

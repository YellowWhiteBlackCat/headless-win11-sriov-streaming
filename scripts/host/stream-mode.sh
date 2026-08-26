#!/usr/bin/env bash
#
# Switch the Windows guest between:
#   on  -> streaming mode (VDD is the only display, 2560x1600@90 @200%)
#   off -> rescue mode (VirtIO rescue display is primary again)
#
# Usage: bash scripts/host/stream-mode.sh {on|off}
set -euo pipefail

MODE="${1:-}"
SSH_HOST="${SSH_HOST:-win-dev}"
GUEST_SCRIPT='C:\Admin\scripts\stream-display-mode.ps1'

case "$MODE" in
    on)  GUEST_MODE='OnlyVdd' ;;
    off) GUEST_MODE='RestoreBoth' ;;
    *)   echo "usage: $0 {on|off}" >&2; exit 1 ;;
esac

echo "Switching guest to $GUEST_MODE ..."
ssh -F ~/.ssh/config "$SSH_HOST" \
    "powershell -NoProfile -ExecutionPolicy Bypass -File $GUEST_SCRIPT -Mode $GUEST_MODE"

echo "Waiting for Sunshine (TCP 47989) ..."
for _ in $(seq 1 30); do
    if nc -zvw 2 192.168.200.2 47989 >/dev/null 2>&1; then
        echo "Sunshine is up."
        exit 0
    fi
    sleep 2
done

echo "Timed out waiting for Sunshine on 192.168.200.2:47989" >&2
exit 1

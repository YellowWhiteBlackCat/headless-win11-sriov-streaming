#!/usr/bin/env bash
#
# Install the Intel SR-IOV VF creator as a systemd oneshot service.
# Must be run as root (or with sudo).
#
# Usage: sudo scripts/host/install-sriov-service.sh [PF] [VF_COUNT]

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root, e.g. sudo $0" >&2
    exit 1
fi

cd "$(dirname "$0")"

PF="${1:-0000:00:02.0}"
VF_COUNT="${2:-2}"
SERVICE_NAME="intel-sriov-vf.service"
CREATE_BIN="/usr/local/sbin/intel-sriov-vf-create"

install -m 0755 sriov-vf-create.sh "$CREATE_BIN"
sed -e "s|@PF@|$PF|g" -e "s|@VF_COUNT@|$VF_COUNT|g" \
    sriov-vf.service > "/etc/systemd/system/$SERVICE_NAME"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl status "$SERVICE_NAME" --no-pager | sed -n '1,12p'

echo "SR-IOV service installed: $SERVICE_NAME (PF=$PF, VF_COUNT=$VF_COUNT)"

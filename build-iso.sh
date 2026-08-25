#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Local secrets (git-ignored): ADMIN_PASSWORD and optionally SSH_PUB_KEY.
if [[ -f secrets.local.env ]]; then
    set -a
    # shellcheck disable=SC1091
    source secrets.local.env
    set +a
fi

ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SSH_PUB_KEY="${SSH_PUB_KEY:-admin_ed25519.pub}"

if [[ ! -f "$SSH_PUB_KEY" ]]; then
    echo "ERROR: SSH public key not found at $SSH_PUB_KEY" >&2
    echo "Generate one with: ssh-keygen -t ed25519 -f admin_ed25519 -N ''" >&2
    exit 1
fi

if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo "ERROR: ADMIN_PASSWORD is not set." >&2
    echo "Export it or create secrets.local.env from secrets.local.env.example." >&2
    exit 1
fi

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp Autounattend.xml bootstrap.cmd bootstrap.ps1 "$SSH_PUB_KEY" "$STAGING/"
printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD" > "$STAGING/bootstrap.env"

shopt -s nullglob
msi_candidates=(openssh/OpenSSH-Win64-*.msi drivers/openssh/OpenSSH-Win64-*.msi)
if (( ${#msi_candidates[@]} > 0 )); then
    cp "${msi_candidates[0]}" "$STAGING/"
else
    echo "WARNING: OpenSSH MSI not found; bootstrap will fall back to Windows capability (requires network)" >&2
fi

xorriso -as mkisofs \
    -o windows-bootstrap.iso \
    -V WINBOOTSTRAP \
    -J \
    -joliet-long \
    -R \
    "$STAGING"

ls -lh windows-bootstrap.iso

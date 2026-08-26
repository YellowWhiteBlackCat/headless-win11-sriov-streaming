#!/usr/bin/env bash
set -euo pipefail

# Restore the reference headless Windows 11 VM from the resting state:
#
#   resting state: VMs off, b390-sriov.service disabled, VFs kept (unbound)
#   restore:       ensure VFs exist -> start win11 -> wait for SSH + Sunshine
#                  -> full verify-stack
#
# Usage:
#   bash scripts/host/restore-vm.sh
#
# Environment overrides: DOM, URI, SSH_HOST, EXPECTED_HOSTNAME, PF, VF_COUNT,
# LOG_DIR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOM="${DOM:-win11}"
URI="${URI:-qemu:///system}"
SSH_HOST="${SSH_HOST:-win-dev}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-WIN11-NEW}"
PF="${PF:-0000:00:02.0}"
VF_COUNT="${VF_COUNT:-2}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/logs}"

VF_CREATE="$REPO_ROOT/scripts/host/sriov-vf-create.sh"
VERIFY_STACK="$REPO_ROOT/scripts/verify-stack.sh"
REPORT="$LOG_DIR/restore-vm-$(date +%Y%m%d-%H%M%S).log"

log() {
    printf '%s\n' "$*" | tee -a "$REPORT"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

run_priv() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

ensure_vfs() {
    log '=== 1. SR-IOV VFs ==='
    local numvfs="/sys/bus/pci/devices/$PF/sriov_numvfs"
    [[ -f "$numvfs" ]] || die "PF $PF not found (sriov_numvfs missing)"

    local current
    current=$(cat "$numvfs")
    if [[ "$current" == "$VF_COUNT" ]]; then
        log "VFs already present: $current (PF=$PF)"
    else
        log "Expected $VF_COUNT VFs but found $current; creating VFs"
        run_priv bash "$VF_CREATE" "$PF" "$VF_COUNT"
    fi

    local missing=0
    local i
    for (( i = 0; i < VF_COUNT; i++ )); do
        if [[ ! -L "/sys/bus/pci/devices/$PF/virtfn$i" ]]; then
            log "WARNING: virtfn$i missing"
            missing=1
        fi
    done
    [[ "$missing" -eq 0 ]] || die "Not all VFs are present"
}

start_domain() {
    log '=== 2. Start VM ==='
    local state
    state=$(virsh -c "$URI" domstate "$DOM" 2>/dev/null || true)
    if [[ "$state" == 'running' ]]; then
        log "VM already running"
        return 0
    fi
    virsh -c "$URI" start "$DOM" | tee -a "$REPORT"
}

wait_ssh() {
    log '=== 3. Wait for SSH ==='
    local deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        local hostname
        hostname=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
            "$SSH_HOST" hostname 2>/dev/null | tr -d '\r\n' || true)
        if [[ "$hostname" == "$EXPECTED_HOSTNAME" ]]; then
            log "SSH ready ($hostname)"
            return 0
        fi
        sleep 5
    done
    die "SSH did not come up within 300s"
}

wait_sunshine() {
    log '=== 4. Wait for Sunshine ==='
    local deadline=$((SECONDS + 300))
    while (( SECONDS < deadline )); do
        local out
        out=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR \
            "$SSH_HOST" \
            'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Admin/scripts/get-ops-state.ps1' \
            2>/dev/null || true)
        if grep -q '^SUNSHINE_PID=[0-9]' <<<"$out" &&
           grep -q 'Found HEVC encoder: hevc_qsv' <<<"$out"; then
            log 'Sunshine running with QuickSync HEVC encoder'
            printf '%s\n' "$out" | tee -a "$REPORT"
            return 0
        fi
        sleep 5
    done
    die 'Sunshine did not become ready within 300s'
}

run_verify() {
    log '=== 5. Full verify-stack ==='
    mkdir -p "$LOG_DIR"
    local out
    out=$(bash "$VERIFY_STACK" 2>&1 || true)
    printf '%s\n' "$out" | tee -a "$REPORT"
    local fail
    fail=$(grep -o 'FAIL=[0-9]*' <<<"$out" | head -1 | cut -d= -f2)
    log "verify-stack FAIL=$fail"
    [[ "$fail" == '0' ]] || die "verify-stack reported $fail failure(s)"
}

main() {
    mkdir -p "$LOG_DIR"
    : > "$REPORT"
    ensure_vfs
    start_domain
    wait_ssh
    wait_sunshine
    run_verify
    log "Restore complete. Report: $REPORT"
}

main

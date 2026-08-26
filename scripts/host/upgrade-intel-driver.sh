#!/usr/bin/env bash
set -euo pipefail

# Orchestrate a pinned Intel Arc graphics driver upgrade for the reference
# headless Windows 11 VM, end to end:
#
#   preflight -> download/verify -> push to guest -> guest upgrade (reboots)
#   -> wait for RunOnce self-heal -> ensure single VDD -> ensure Sunshine
#   -> full verify-stack -> written report
#
# Usage:
#   bash scripts/host/upgrade-intel-driver.sh [options]
#
# Options:
#   -f, --file PATH           use a local driver exe instead of downloading
#   -e, --expect-version VER  driver version to wait for after reboot
#                             (default: 32.0.101.8991)
#   -S, --status-only         collect and verify current state, make no changes
#   -q, --skip-verify-stack   do not run the final verify-stack.sh
#   -h, --help                show this help
#
# Environment overrides (same names as scripts/download-assets.sh):
#   INTEL_URL, INTEL_SHA, DOM, URI, SSH_HOST, LOG_DIR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOM="${DOM:-win11}"
URI="${URI:-qemu:///system}"
SSH_HOST="${SSH_HOST:-win-dev}"
LOG_DIR="${LOG_DIR:-$REPO_ROOT/logs}"
DRIVERS_DIR="$REPO_ROOT/drivers/IntelArcDriver"
GUEST_DRIVER_DIR='C:/Admin/drivers/IntelArcDriver'

INTEL_URL="${INTEL_URL:-https://downloadmirror.intel.com/926884/gfx_win_101.8991.exe}"
INTEL_SHA="${INTEL_SHA:-ea230464eb1c58f98d7b379b16369033bf4eeff55af1a8a3b78026adf2bb425d}"

EXPECT_VER='32.0.101.8991'
LOCAL_EXE=''
STATUS_ONLY=0
SKIP_VERIFY=0
REPORT="$LOG_DIR/upgrade-intel-driver-$(date +%Y%m%d-%H%M%S).log"

GUEST_SCRIPTS=(
    upgrade-intel-driver.ps1
    rebuild-vdd.ps1
    get-driver-version.ps1
    get-ops-state.ps1
)

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    printf '%s\n' "$*" | tee -a "$REPORT"
}

ssh_guest() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR "$SSH_HOST" "$@" 2>&1
}

ssh_guest_ps() {
    ssh_guest "powershell -NoProfile -ExecutionPolicy Bypass -File $1"
}

ensure_report_dir() {
    mkdir -p "$LOG_DIR"
    : > "$REPORT"
}

preflight() {
    log '=== 1. Preflight ==='
    local state
    state=$(virsh -c "$URI" domstate "$DOM" 2>/dev/null || true)
    [[ "$state" == 'running' ]] || die "VM $DOM is not running (state=$state)"
    log "VM $DOM running"

    local hostname
    hostname=$(ssh_guest hostname | tr -d '\r\n' || true)
    [[ -n "$hostname" ]] || die "SSH to $SSH_HOST failed"
    log "SSH hostname=$hostname"

    local version
    version=$(ssh_guest_ps 'C:/Admin/scripts/get-driver-version.ps1' | tr -d '\r\n' || true)
    log "Current guest driver: ${version:-unknown}"
}

resolve_driver() {
    log '=== 2. Driver package ==='
    if [[ -n "$LOCAL_EXE" ]]; then
        DRIVER_FILE="$LOCAL_EXE"
        log "Using local driver: $DRIVER_FILE"
    else
        local name
        name=$(basename "$INTEL_URL")
        DRIVER_FILE="$DRIVERS_DIR/$name"
        if [[ -f "$DRIVER_FILE" ]]; then
            log "Driver already present: $DRIVER_FILE"
        else
            log "Downloading $INTEL_URL"
            mkdir -p "$DRIVERS_DIR"
            curl -fL --retry 3 --retry-delay 2 -o "$DRIVER_FILE" "$INTEL_URL" 2>&1 | tee -a "$REPORT"
        fi
    fi
    [[ -f "$DRIVER_FILE" ]] || die "Driver file not found: $DRIVER_FILE"

    log "Verifying SHA-256"
    local actual
    actual=$(sha256sum "$DRIVER_FILE" | awk '{print $1}')
    if [[ "$actual" != "$INTEL_SHA" ]]; then
        die "SHA-256 mismatch: expected $INTEL_SHA, got $actual"
    fi
    log "SHA-256 OK: $actual"
}

push_driver() {
    log '=== 3. Push to guest ==='
    local base
    base=$(basename "$DRIVER_FILE")
    GUEST_EXE="$GUEST_DRIVER_DIR/$base"
    scp -q -o LogLevel=ERROR "$DRIVER_FILE" "$SSH_HOST:$GUEST_EXE" 2>&1 | tee -a "$REPORT"

    local guest_hash
    guest_hash=$(ssh_guest "powershell -NoProfile -Command \"(Get-FileHash '$GUEST_EXE' -Algorithm SHA256).Hash\"" | tr -d '\r\n' || true)
    if [[ "${guest_hash,,}" != "${INTEL_SHA,,}" ]]; then
        die "Guest hash mismatch: ${guest_hash:-no-hash}"
    fi
    log "Guest copy verified ($GUEST_EXE)"
}

sync_guest_scripts() {
    log '=== 4. Sync guest ops scripts ==='
    local script
    for script in "${GUEST_SCRIPTS[@]}"; do
        scp -q -o LogLevel=ERROR "$REPO_ROOT/scripts/guest/$script" "$SSH_HOST:C:/Admin/scripts/$script" 2>&1 | tee -a "$REPORT"
    done
    log "Synced ${#GUEST_SCRIPTS[@]} scripts to C:\\Admin\\scripts"
}

run_upgrade() {
    log '=== 5. Guest driver upgrade (auto-reboot) ==='
    ssh_guest "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Admin/scripts/upgrade-intel-driver.ps1 -DriverExe $GUEST_EXE" | tee -a "$REPORT"
}

wait_for_post_reboot() {
    log '=== 6. Waiting for reboot + RunOnce self-heal ==='
    local deadline=$((SECONDS + 900))
    while (( SECONDS < deadline )); do
        local out
        out=$(ssh_guest_ps 'C:/Admin/scripts/get-ops-state.ps1' || true)
        if grep -q "^DRIVER=$EXPECT_VER$" <<<"$out" &&
           grep -q 'Post-reboot upgrade phase finished' <<<"$out"; then
            log "Post-reboot phase finished; driver=$EXPECT_VER"
            printf '%s\n' "$out" | tee -a "$REPORT"
            return 0
        fi
        log '  still booting/healing...'
        sleep 15
    done
    log 'Timed out waiting for post-reboot completion'
    return 1
}

ensure_vdd() {
    log '=== 7. VDD integrity ==='
    local out
    out=$(ssh_guest_ps 'C:/Admin/scripts/get-ops-state.ps1' || true)
    local count
    count=$(grep -o '^VDD_COUNT=[0-9]*' <<<"$out" | cut -d= -f2)
    local ok_status=1
    if [[ "$count" == '1' ]] && grep -Fqx 'VDD ROOT\DISPLAY\0000 status=OK' <<<"$out"; then
        ok_status=0
    fi
    if (( ok_status )); then
        log "VDD state not clean (count=$count); running rebuild-vdd.ps1"
        ssh_guest 'powershell -NoProfile -ExecutionPolicy Bypass -File C:/Admin/scripts/rebuild-vdd.ps1' | tee -a "$REPORT"
    else
        log 'Single VDD node OK; no rebuild needed'
    fi
}

ensure_sunshine() {
    log '=== 8. Sunshine ==='
    local out
    out=$(ssh_guest_ps 'C:/Admin/scripts/get-ops-state.ps1' || true)
    if ! grep -q '^SUNSHINE_PID=[0-9]' <<<"$out"; then
        log 'Sunshine not running; starting SunshineUser task (interactive session)'
        ssh_guest 'powershell -NoProfile -Command "Start-ScheduledTask -TaskName SunshineUser"' | tee -a "$REPORT"
        sleep 20
        out=$(ssh_guest_ps 'C:/Admin/scripts/get-ops-state.ps1' || true)
    fi
    if grep -q '^SUNSHINE_PID=[0-9]' <<<"$out" &&
       grep -q 'Found HEVC encoder: hevc_qsv' <<<"$out"; then
        log 'Sunshine running with QuickSync HEVC encoder'
    else
        log 'WARNING: Sunshine did not come up cleanly; inspect the report'
    fi
    printf '%s\n' "$out" | tee -a "$REPORT"
}

run_verify() {
    if (( SKIP_VERIFY )); then
        log '=== 9. verify-stack skipped (-q) ==='
        return 0
    fi
    log '=== 9. Full verify-stack ==='
    local out
    out=$(bash "$REPO_ROOT/scripts/verify-stack.sh" 2>&1 || true)
    printf '%s\n' "$out" | tee -a "$REPORT"
    local fail
    fail=$(grep -o 'FAIL=[0-9]*' <<<"$out" | head -1 | cut -d= -f2)
    log "verify-stack FAIL=$fail"
}

collect_status() {
    log '=== Status only ==='
    ssh_guest_ps 'C:/Admin/scripts/get-ops-state.ps1' | tee -a "$REPORT"
    run_verify
}

main() {
    ensure_report_dir
    preflight
    if (( STATUS_ONLY )); then
        collect_status
    else
        resolve_driver
        push_driver
        sync_guest_scripts
        run_upgrade
        wait_for_post_reboot
        ensure_vdd
        ensure_sunshine
        run_verify
    fi
    log "Report: $REPORT"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)
            LOCAL_EXE="${2:?missing path}"
            shift 2
            ;;
        -e|--expect-version)
            EXPECT_VER="${2:?missing version}"
            shift 2
            ;;
        -S|--status-only)
            STATUS_ONLY=1
            shift
            ;;
        -q|--skip-verify-stack)
            SKIP_VERIFY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

main

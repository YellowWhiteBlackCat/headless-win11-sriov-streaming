#!/usr/bin/env bash
set -u

DOM="${DOM:-win11}"
URI="${URI:-qemu:///system}"
SSH_HOST="${SSH_HOST:-win-dev}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-WIN11-NEW}"
EXPECTED_IP="${EXPECTED_IP:-192.168.122.50}"
LOG_DIR="${LOG_DIR:-$(cd "$(dirname "$0")/.." && pwd)/logs}"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo "===== 1. VM state ====="
state=$(virsh -c "$URI" domstate "$DOM" 2>/dev/null || true)
if [ "$state" = "running" ]; then pass "domstate=$state"; else fail "domstate=$state"; fi

echo "===== 2. QGA guest-ping ====="
if virsh -c "$URI" qemu-agent-command "$DOM" '{"execute":"guest-ping"}' 2>/dev/null | grep -q '"return":{}'; then
    pass "QGA guest-ping"
else
    fail "QGA guest-ping"
fi

echo "===== 3. Guest IP via agent ====="
addrs=$(virsh -c "$URI" domifaddr "$DOM" --source agent 2>/dev/null || true)
if echo "$addrs" | grep -q "$EXPECTED_IP"; then
    pass "guest IP $EXPECTED_IP"
else
    fail "guest IP missing: $addrs"
fi

echo "===== 4. SSH ====="
host=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" hostname 2>/dev/null || true)
host=$(printf '%s' "$host" | tr -d '\r\n')
if [ "$host" = "$EXPECTED_HOSTNAME" ]; then
    pass "SSH hostname=$host"
else
    fail "SSH hostname=$host"
fi

echo "===== 5. VNC rescue display ====="
mkdir -p "$LOG_DIR"
# Wake the display first: Windows may have turned off the VirtIO monitor after idle.
virsh -c "$URI" send-key "$DOM" KEY_SCROLLLOCK >/dev/null 2>&1 || true
sleep 2
shot="$LOG_DIR/verify-$(date +%H%M%S).png"
if virsh -c "$URI" screenshot "$DOM" "$shot" >/dev/null 2>&1; then
    mean=$(identify -format '%[mean]' "$shot" 2>/dev/null || echo 0)
    colors=$(identify -format '%k' "$shot" 2>/dev/null || echo 0)
    if [ "${mean%%.*}" -gt 100 ] && [ "$colors" -gt 10 ]; then
        pass "VNC screenshot mean=$mean colors=$colors -> $shot"
    else
        fail "VNC screenshot looks blank mean=$mean colors=$colors -> $shot"
    fi
else
    fail "virsh screenshot failed"
fi

echo "===== 6. Guest services / displays / QSV ====="
diag=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" \
    'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\guest-verify.ps1' 2>/dev/null || true)

if echo "$diag" | grep -q 'DISPLAY OK.*Virtual Display Driver' &&
   echo "$diag" | grep -q 'DISPLAY OK.*Red Hat VirtIO GPU' &&
   echo "$diag" | grep -q 'DISPLAY OK.*Intel(R) Arc(TM) B390 GPU'; then
    pass "three display adapters present"
else
    fail "display adapter list incomplete: $(echo "$diag" | grep DISPLAY | tr '\n' ';')"
fi

if echo "$diag" | grep -q 'SERVICE Running.*QEMU-GA'; then
    pass "QEMU-GA running"
else
    fail "QEMU-GA not running"
fi
if echo "$diag" | grep -q 'SERVICE Running.*sshd'; then
    pass "sshd running"
else
    fail "sshd missing"
fi
if echo "$diag" | grep -q 'SERVICE Running.*SunshineService'; then
    pass "SunshineService running"
else
    fail "SunshineService missing"
fi
if echo "$diag" | grep -q 'QSV OK h264_qsv' &&
   echo "$diag" | grep -q 'QSV OK hevc_qsv' &&
   echo "$diag" | grep -q 'QSV OK av1_qsv'; then
    pass "QuickSync encoders found"
else
    fail "QuickSync encoders missing: $(echo "$diag" | grep QSV | tr '\n' ';')"
fi

echo "===== 7. Out-of-box apps ====="
appdiag=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_HOST" \
    'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Admin\scripts\verify-apps.ps1' 2>/dev/null || true)
if echo "$appdiag" | grep -q 'APP OK Google Chrome' &&
   echo "$appdiag" | grep -q 'APP OK 7-Zip' &&
   echo "$appdiag" | grep -q 'APP OK Notepad++' &&
   echo "$appdiag" | grep -q 'APP OK Git' &&
   echo "$appdiag" | grep -q 'APP OK winget'; then
    pass "required apps + winget installed"
else
    fail "app manifest incomplete: $(echo "$appdiag" | grep '^APP' | tr '\n' ';')"
fi

echo "===== 8. System-wide UTF-8 ====="
if echo "$diag" | grep -q 'UTF8 OK system-wide'; then
    pass "system-wide UTF-8 (ACP/OEMCP=65001)"
else
    fail "system-wide UTF-8: $(echo "$diag" | grep CODEPAGE | tr '\n' ';')"
fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

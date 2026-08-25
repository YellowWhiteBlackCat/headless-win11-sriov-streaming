#!/usr/bin/env bash
#
# Download every third-party asset needed by the deployment into drivers/ and
# apps/winget/. These directories are git-ignored on purpose: binaries should
# be fetched, not committed.
#
# Usage:
#   scripts/download-assets.sh [--skip-intel] [--skip-winget] [--with-virtio]
#
# The reference SHA-256 values live in assets.sha256 at the repository root.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRIVERS="$ROOT/drivers"
WINGET="$ROOT/apps/winget"

SKIP_INTEL=0
SKIP_WINGET=0
WITH_VIRTIO=0

for arg in "$@"; do
    case "$arg" in
        --skip-intel) SKIP_INTEL=1 ;;
        --skip-winget) SKIP_WINGET=1 ;;
        --with-virtio) WITH_VIRTIO=1 ;;
        --help)
            sed -n '2,12p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1
            ;;
    esac
done

mkdir -p "$DRIVERS/IntelArcDriver" "$DRIVERS/openssh" "$DRIVERS/Sunshine" "$WINGET"

verify_sha() {
    local file="$1" expected="$2"
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: SHA-256 mismatch for $file" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        rm -f "$file"
        exit 1
    fi
    echo "OK: $file"
}

download() {
    local url="$1" dest="$2"
    if [[ -f "$dest" ]]; then
        echo "exists: $dest"
        return
    fi
    echo "downloading: $url"
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
}

# --- Intel Arc Graphics driver (Windows guest) -------------------------------
INTEL_URL="${INTEL_URL:-https://downloadmirror.intel.com/926177/gfx_win_101.8974.exe}"
INTEL_SHA="55f70b3bf4df43b46f1c776903ded06e6f5acdb73538d005f4443d3043bd6853"
INTEL_DEST="$DRIVERS/IntelArcDriver/gfx_win_101.8974.exe"

if [[ "$SKIP_INTEL" -eq 0 ]]; then
    download "$INTEL_URL" "$INTEL_DEST"
    verify_sha "$INTEL_DEST" "$INTEL_SHA"
else
    echo "SKIP: Intel Arc driver"
fi

# --- Virtual-Display-Driver (IDD) --------------------------------------------
VDD_URL="${VDD_URL:-https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VDD.Control.25.7.23.zip}"
VDD_SHA="a701f2272e9fcf382849b24f913c6dd07597b3b1116525f2e90182f019609154"
VDD_ZIP="$DRIVERS/VDD.Control.25.7.23.zip"

if [[ ! -f "$DRIVERS/VDD-Control/SignedDrivers/x86/VDD/MttVDD.inf" ]]; then
    download "$VDD_URL" "$VDD_ZIP"
    verify_sha "$VDD_ZIP" "$VDD_SHA"
    echo "extracting $VDD_ZIP -> $DRIVERS/VDD-Control/"
    mkdir -p "$DRIVERS/VDD-Control"
    unzip -q -o "$VDD_ZIP" -d "$DRIVERS/VDD-Control"
else
    echo "exists: $DRIVERS/VDD-Control (already extracted)"
fi

# --- OpenSSH for Windows -----------------------------------------------------
SSH_URL="${SSH_URL:-https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64-v9.8.3.0.msi}"
SSH_SHA="c8a8c7e21136a099665c2fad9accb41152d129466b719ea71678bab665e03389"
SSH_DEST="$DRIVERS/openssh/OpenSSH-Win64-v9.8.3.0.msi"

download "$SSH_URL" "$SSH_DEST"
verify_sha "$SSH_DEST" "$SSH_SHA"

# --- winget / Desktop App Installer (offline bootstrap) ----------------------
if [[ "$SKIP_WINGET" -eq 0 ]]; then
    WINGET_TAG="${WINGET_TAG:-v1.29.290}"
    WINGET_BUNDLE_URL="https://github.com/microsoft/winget-cli/releases/download/${WINGET_TAG}/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    WINGET_DEPS_URL="https://github.com/microsoft/winget-cli/releases/download/${WINGET_TAG}/DesktopAppInstaller_Dependencies.zip"
    WINGET_BUNDLE_SHA="6824b6e9484ab24687d99a0c829d2bcbcc7849a70a4d0f596fc43c89d20dff15"
    WINGET_DEPS_SHA="50c377516749002dcdda9c8e52f26e8e2ea73d52131ce96ffd082dcf60ca6677"

    download "$WINGET_BUNDLE_URL" "$WINGET/apps-winget.msixbundle"
    verify_sha "$WINGET/apps-winget.msixbundle" "$WINGET_BUNDLE_SHA"
    mv -f "$WINGET/apps-winget.msixbundle" "$WINGET/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"

    download "$WINGET_DEPS_URL" "$WINGET/apps-winget-deps.zip"
    verify_sha "$WINGET/apps-winget-deps.zip" "$WINGET_DEPS_SHA"
    mv -f "$WINGET/apps-winget-deps.zip" "$WINGET/DesktopAppInstaller_Dependencies.zip"
else
    echo "SKIP: winget bundle"
fi

# --- Sunshine (Windows portable) ----------------------------------------------
SUNSHINE_TAG="${SUNSHINE_TAG:-v2026.516.143833}"
SUNSHINE_URL="https://github.com/LizardByte/Sunshine/releases/download/${SUNSHINE_TAG}/Sunshine-Windows-AMD64-portable.zip"
SUNSHINE_SHA="0a3af3dde43b8f2c94ffe04b850ad736d6e1be2b75906779d7094a5ad9d4783b"
SUNSHINE_ZIP="$DRIVERS/Sunshine-portable.zip"

if [[ ! -f "$DRIVERS/Sunshine/sunshine.exe" ]]; then
    download "$SUNSHINE_URL" "$SUNSHINE_ZIP"
    verify_sha "$SUNSHINE_ZIP" "$SUNSHINE_SHA"
    echo "extracting $SUNSHINE_ZIP -> $DRIVERS/Sunshine/"
    tmp="$(mktemp -d)"
    unzip -q -o "$SUNSHINE_ZIP" -d "$tmp"
    cp -a "$tmp/Sunshine/." "$DRIVERS/Sunshine/"
    rm -rf "$tmp"
else
    echo "exists: $DRIVERS/Sunshine (already extracted)"
fi

# --- virtio-win (optional, large) ---------------------------------------------
if [[ "$WITH_VIRTIO" -eq 1 ]]; then
    VIRTIO_BASE="${VIRTIO_BASE:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio}"
    VIRTIO_ISO="$DRIVERS/virtio-win.iso"
    download "$VIRTIO_BASE/virtio-win.iso" "$VIRTIO_ISO"
    download "$VIRTIO_BASE/CHECKSUM" "$DRIVERS/virtio-win.CHECKSUM"
    (cd "$DRIVERS" && sha256sum -c <(grep -i 'virtio-win.iso' virtio-win.CHECKSUM))
else
    echo "SKIP: virtio-win ISO (re-run with --with-virtio if needed)"
fi

# --- Intel Display Virtualization source --------------------------------------
if [[ ! -d "$DRIVERS/intel-display-virt/.git" ]]; then
    echo "cloning Intel Display-Virtualization-for-Windows-OS (tag zerocopy-version-2400)"
    git clone --depth 1 --branch zerocopy-version-2400 \
        https://github.com/intel/Display-Virtualization-for-Windows-OS.git \
        "$DRIVERS/intel-display-virt"
else
    echo "exists: $DRIVERS/intel-display-virt"
fi

echo ""
echo "NOTE: Intel 'ZCBuild_*_Installer.zip' packages used by the reference host"
echo "are not publicly mirrored; keep any copies you already have under drivers/."
echo "The Intel source tree above is the canonical place to build them."
echo ""
echo "DONE"

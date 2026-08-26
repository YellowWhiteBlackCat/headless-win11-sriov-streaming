#!/usr/bin/env bash
# Build Sunshine v2026.516.143833 with the qsv_async_depth config option.
# Run from MSYS2 UCRT64 (see build-sunshine-patched.ps1). Produces a staged
# build in /c/Admin/build/sunshine-stage/.
set -euo pipefail

export MSYSTEM=UCRT64
export PATH="/ucrt64/bin:/usr/bin:$PATH"
export BRANCH=release
export BUILD_VERSION=2026.516.143833

SRC=/c/Admin/build/sunshine-src
STAGE=/c/Admin/build/sunshine-stage
LOG=/c/Admin/logs/build-sunshine.log
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "=== Sunshine patched build start ==="

if [[ ! -d "$SRC/.git" ]]; then
  log "Cloning Sunshine v2026.516.143833 with submodules"
  git clone --depth 1 --branch v2026.516.143833 --recurse-submodules \
    https://github.com/LizardByte/Sunshine.git "$SRC"
fi

cd "$SRC"
git checkout -- \
  src/config.h src/config.cpp src/video.cpp \
  cmake/dependencies/Boost_Sunshine.cmake \
  cmake/packaging/windows_wix.cmake 2>/dev/null || true
git apply /c/Admin/build/sunshine-qsv-async-depth.patch
log "Patch state: $(grep -c 'qsv_async_depth' src/config.h src/config.cpp src/video.cpp | tr '\n' ' ')"

rm -rf build
log "Configuring CMake"
cmake -B build -G Ninja -S . \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DBUILD_WERROR=OFF \
  -DSUNSHINE_SKIP_WIX=ON \
  -DSUNSHINE_ASSETS_DIR=assets \
  -DSUNSHINE_PUBLISHER_NAME=zhugenanbei \
  -DSUNSHINE_PUBLISHER_WEBSITE="https://github.com/YellowWhiteBlackCat" \
  -DSUNSHINE_PUBLISHER_ISSUE_URL="https://github.com/YellowWhiteBlackCat/headless-win11-sriov-streaming/issues" \
  | tee -a "$LOG"

log "Building (this can take a while)"
ninja -C build 2>&1 | tee -a "$LOG"

if [[ ! -f build/sunshine.exe ]]; then
  log "ERROR: build/sunshine.exe missing"
  exit 1
fi

log "Staging patched build"
rm -rf "$STAGE"
mkdir -p "$STAGE/assets"
cp build/sunshine.exe "$STAGE/"
cp -r build/assets/* "$STAGE/assets/" 2>/dev/null || true

# Copy every runtime DLL reported by ldd (Qt, FFmpeg, boost, etc.).
while IFS= read -r dll; do
  [[ -n "$dll" ]] && cp -f "$dll" "$STAGE/"
done < <(ldd build/sunshine.exe | awk '/=> \// {print $3; next} /^\s+\// {print $1}')

# zlib1.dll is loaded dynamically by OpenSSL (not listed by ldd). The official
# portable package ships it; without it HTTPS/TLS breaks at runtime.
if [[ -f /ucrt64/bin/zlib1.dll ]]; then
  cp -f /ucrt64/bin/zlib1.dll "$STAGE/"
elif [[ -f /c/Admin/Sunshine/zlib1.dll ]]; then
  cp -f /c/Admin/Sunshine/zlib1.dll "$STAGE/"
else
  log "WARNING: zlib1.dll not found; TLS may fail"
fi

# Also copy the bundled tools for diagnostics.
mkdir -p "$STAGE/tools"
for t in audio-info dxgi-info sunshinesvc; do
  if [[ -f "build/tools/$t.exe" ]]; then
    cp "build/tools/$t.exe" "$STAGE/tools/"
  fi
done

log "Stage contents:"
ls -1 "$STAGE" | tee -a "$LOG"
log "=== Build finished OK ==="

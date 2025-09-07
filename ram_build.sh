#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
# Ram-based package build script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_FILE="$HOME/cerebro_scripts/ram_build.log"

echo "[*] Starting RAM build: $(date)" | tee -a "$LOG_FILE"

# Auto-detect RAM in MB
MEM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
RAM_BUILD=$(( MEM_MB - 1536 )) # Use all RAM minus 1.5GB
if (( RAM_BUILD < 512 )); then
    echo "[!] Not enough RAM, using fallback 512MB" | tee -a "$LOG_FILE"
    RAM_BUILD=512
fi

echo "[*] Using $RAM_BUILD MB tmpfs for build" | tee -a "$LOG_FILE"

# Mount tmpfs
BUILD_TMP=$(mktemp -d)
sudo mount -t tmpfs -o size=${RAM_BUILD}M tmpfs "$BUILD_TMP"

# Detect CMake generator
if command -v ninja >/dev/null 2>&1; then
    CMAKE_GEN="-G Ninja"
else
    CMAKE_GEN=""
fi

export CCACHE_DIR="$HOME/.ccache"
export USE_CCACHE=1

echo "[*] Starting build in $BUILD_TMP" | tee -a "$LOG_FILE"
cd "$BUILD_TMP" || exit 1

# Example build command
cmake $CMAKE_GEN /path/to/source -DCMAKE_BUILD_TYPE=Release
cmake --build . --parallel "$(nproc)" | tee -a "$LOG_FILE"

echo "[*] Build finished, cleaning tmpfs" | tee -a "$LOG_FILE"
cd "$HOME"
sudo umount "$BUILD_TMP"
rm -rf "$BUILD_TMP"

echo "[*] Done: $(date)" | tee -a "$LOG_FILE"

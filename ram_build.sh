#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
# RAM-based package build with mold, ninja, and smart ccache

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_FILE="$SCRIPT_DIR/ram_build.log"

echo "[*] Starting RAM build: $(date)" | tee -a "$LOG_FILE"

# Auto-detect RAM in MB
MEM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
RAM_BUILD=$(( MEM_MB / 2 )) # Use half of RAM
(( RAM_BUILD < 512 )) && RAM_BUILD=512

echo "[*] Using $RAM_BUILD MB tmpfs for build" | tee -a "$LOG_FILE"

# Mount tmpfs
BUILD_TMP=$(mktemp -d)
sudo mount -t tmpfs -o size=${RAM_BUILD}M tmpfs "$BUILD_TMP"

# Detect source folder
SRC_DIR="${1:-$PWD}"
if [ ! -d "$SRC_DIR" ]; then
    echo "[!] Source folder $SRC_DIR does not exist!" | tee -a "$LOG_FILE"
    exit 1
fi

# Detect CMake generator
CMAKE_GEN=""
command -v ninja >/dev/null 2>&1 && CMAKE_GEN="-G Ninja"

# Setup ccache and mold
export CCACHE_DIR="$HOME/.ccache"
export USE_CCACHE=1
export CCACHE_MAXSIZE=10G
export CCACHE_COMPILERCHECK=content
export LD=ld.mold

# Check for previous build cache
CACHE_DIR="$SRC_DIR/build_cache"
mkdir -p "$CACHE_DIR"

echo "[*] Starting build from $SRC_DIR in $BUILD_TMP" | tee -a "$LOG_FILE"
cd "$BUILD_TMP" || exit 1

# Use persistent cache
cmake $CMAKE_GEN "$SRC_DIR" -B . -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
      -DCMAKE_LINKER=ld.mold

# Build with parallelization and logging
cmake --build . --parallel "$(nproc)" | tee -a "$LOG_FILE"

# Copy compiled objects back to persistent cache
rsync -a --progress "$BUILD_TMP/" "$CACHE_DIR/"

echo "[*] Build finished, cleaning tmpfs" | tee -a "$LOG_FILE"
cd "$HOME"
sudo umount "$BUILD_TMP"
rm -rf "$BUILD_TMP"

echo "[*] Done: $(date)" | tee -a "$LOG_FILE"

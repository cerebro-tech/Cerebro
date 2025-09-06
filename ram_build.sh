#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="$HOME/cerebro_scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ram_build.log"

echo "[*] Starting RAM build environment..." | tee -a "$LOG_FILE"

# Detect RAM, ZRAM, and SWAP
RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2 / 1024}')
ZRAM_MB=$(swapon --show | awk '/zram/ {sum += $3} END {print sum/1024}')
SWAP_MB=$(swapon --show | awk '/partition/ {sum += $3} END {print sum/1024}')

: "${ZRAM_MB:=0}"
: "${SWAP_MB:=0}"

# Reserve 1.5GB from real RAM
SAFE_RAM=$(( RAM_MB - 1536 ))
[ $SAFE_RAM -lt 512 ] && SAFE_RAM=512

# tmpfs size = safe RAM + ZRAM + SWAP
TMPFS_SIZE=$(( SAFE_RAM + ZRAM_MB + SWAP_MB ))
echo "[*] tmpfs size set to ${TMPFS_SIZE}M" | tee -a "$LOG_FILE"

# Create build dir
BUILD_DIR="/tmp/ram_build.$$"
mkdir -p "$BUILD_DIR"

# Mount tmpfs
sudo mount -t tmpfs -o size=${TMPFS_SIZE}M tmpfs "$BUILD_DIR"

cleanup() {
  echo "[*] Cleaning up RAM build..." | tee -a "$LOG_FILE"
  sudo umount "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

cd "$BUILD_DIR"

# Auto-detect source dir if CMake
if [ -f "$OLDPWD/CMakeLists.txt" ]; then
  SRC_DIR="$OLDPWD"
else
  SRC_DIR="."
fi

echo "[*] Building from $SRC_DIR ..." | tee -a "$LOG_FILE"
"$@" 2>&1 | tee -a "$LOG_FILE"

echo "[✔] Build finished." | tee -a "$LOG_FILE"

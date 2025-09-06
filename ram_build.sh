#!/usr/bin/env bash
set -euo pipefail

# --- Detect caller for logging ---
CALLER="manual"
if [[ "${0##*/}" == "rparu" ]] || [[ "${0##*/}" == "paru" ]]; then
  CALLER="paru"
elif [[ "${0##*/}" == "rpacman" ]] || [[ "${0##*/}" == "pacman" ]]; then
  CALLER="pacman"
fi

LOG_DIR="$HOME/cerebro_scripts/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/ram_build-${CALLER}.log"

echo "[*] Starting RAM build (caller: $CALLER)..." | tee -a "$LOG_FILE"

# --- Detect RAM, ZRAM, SWAP ---
RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2 / 1024}')
ZRAM_MB=$(swapon --show | awk '/zram/ {sum += $3} END {print sum/1024}')
SWAP_MB=$(swapon --show | awk '/partition/ {sum += $3} END {print sum/1024}')

: "${ZRAM_MB:=0}"
: "${SWAP_MB:=0}"

# Reserve 1.5 GB RAM
SAFE_RAM=$(( RAM_MB - 1536 ))
[ $SAFE_RAM -lt 512 ] && SAFE_RAM=512

# tmpfs size = safe RAM + ZRAM + SWAP
TMPFS_SIZE=$(( SAFE_RAM + ZRAM_MB + SWAP_MB ))
echo "[*] tmpfs size set to ${TMPFS_SIZE}M" | tee -a "$LOG_FILE"

# --- Mount tmpfs ---
BUILD_DIR="/tmp/ram_build.$$"
mkdir -p "$BUILD_DIR"
sudo mount -t tmpfs -o size=${TMPFS_SIZE}M tmpfs "$BUILD_DIR"

cleanup() {
  echo "[*] Cleaning up RAM build..." | tee -a "$LOG_FILE"
  sudo umount "$BUILD_DIR"
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

cd "$BUILD_DIR"

# --- Auto-detect CMake project ---
if [ -f "$OLDPWD/CMakeLists.txt" ]; then
  SRC_DIR="$OLDPWD"
else
  SRC_DIR="."
fi

echo "[*] Building from $SRC_DIR ..." | tee -a "$LOG_FILE"

# --- Run build ---
"$@" 2>&1 | tee -a "$LOG_FILE"

echo "[✔] Build finished (caller: $CALLER)" | tee -a "$LOG_FILE"

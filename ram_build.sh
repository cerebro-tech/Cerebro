#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_PATH="$1"
LOG_FILE="$2"

# Detect RAM and calculate tmpfs size
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
USE_RAM_MB=$(( TOTAL_RAM_MB / 2 ))  # Use half RAM for tmpfs

# Build in tmpfs
TMPFS_DIR="/tmp/ram_build"
mkdir -p "$TMPFS_DIR"
sudo mount -t tmpfs -o size=${USE_RAM_MB}M tmpfs "$TMPFS_DIR"
cp -r "$BUILD_PATH"/* "$TMPFS_DIR/"

echo "[*] Building in RAM..."
cd "$TMPFS_DIR"
makepkg -sri --noconfirm &> "$LOG_FILE"

echo "[*] Build completed, cleaning up..."
sudo umount "$TMPFS_DIR"
rm -rf "$TMPFS_DIR"

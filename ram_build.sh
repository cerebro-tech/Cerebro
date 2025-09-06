#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
# Build any source in RAM with optional ZRAM + swap fallback

set -euo pipefail

# --- Detect RAM ---
TOTAL_RAM=$(awk '/MemTotal/ {print $2}' /proc/meminfo) # KB
TOTAL_RAM_MB=$((TOTAL_RAM / 1024))
AVAILABLE_RAM_MB=$((TOTAL_RAM_MB - 1500)) # leave 1.5GB for system
[[ $AVAILABLE_RAM_MB -lt 512 ]] && AVAILABLE_RAM_MB=512

# --- Detect swap ---
SWAP_ACTIVE=$(swapon --show=NAME | wc -l)
USE_SWAP=true
if [[ $SWAP_ACTIVE -le 0 ]]; then
    USE_SWAP=false
fi

# --- ZRAM config ---
ZRAM_SIZE_MB=$(( TOTAL_RAM_MB / 2 ))
sudo modprobe zram num_devices=1
echo $((ZRAM_SIZE_MB * 1024 * 1024)) | sudo tee /sys/block/zram0/disksize
sudo mkswap /dev/zram0
sudo swapon -p 100 /dev/zram0

# --- Activate swap if exists ---
if $USE_SWAP; then
    sudo swapon -a
fi

# --- RAM build dir ---
SRC_DIR="${1:-$(pwd)}"
BUILD_DIR=$(mktemp -d /dev/shm/ram_build_XXXX)
echo "[*] Building in RAM: $BUILD_DIR"
cd "$SRC_DIR"

# --- Backup makepkg.conf / rust.conf ---
for cfg in /etc/makepkg.conf ~/.cargo/config.toml; do
    [[ -f "$cfg" ]] && cp "$cfg" "$cfg.bak"
done

# --- Download optimized configs ---
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /etc/makepkg.conf
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o ~/.cargo/config.toml

# --- Build ---
echo "[*] Starting build..."
if [[ $# -gt 1 ]]; then
    shift
    "$@" | tee -a "$SRC_DIR/ram_build-paru.log"
else
    echo "[*] No command provided to build"
fi

# --- Cleanup ---
echo "[*] Cleaning RAM build directory..."
rm -rf "$BUILD_DIR"
sudo swapoff /dev/zram0 || true
sudo rmmod zram || true

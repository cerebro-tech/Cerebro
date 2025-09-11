#!/usr/bin/env bash
set -euo pipefail

RAM_DIR="/mnt/cerebro_ram_build"
LOG_DIR="$HOME/cerebro/log"
LOCAL_OUT="$HOME/cerebro/out"
ZRAM_DEV="/dev/zram0"

mkdir -p "$LOG_DIR" "$LOCAL_OUT"

# ------------------------------
# Setup zram swap
# ------------------------------
setup_zram() {
    if [[ ! -b $ZRAM_DEV ]]; then
        echo "[*] Loading zram module..."
        sudo modprobe zram
    fi

    local current_size
    current_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)

    if [[ "$current_size" -eq 0 ]]; then
        MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
        echo "[*] Initializing zram0 with ${MEM_MB}MB (all available RAM)..."
        echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize > /dev/null
        sudo mkswap $ZRAM_DEV
        sudo swapon -p 150 $ZRAM_DEV
    else
        echo "[*] zram0 already active (size: $((current_size/1024/1024))MB), skipping re-init."
    fi
}

# ------------------------------
# Mount tmpfs for build
# ------------------------------
mount_ramdisk() {
    echo "[*] Mounting tmpfs for build..."
    sudo mkdir -p "$RAM_DIR"
    sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
}

# ------------------------------
# Cleanup function
# ------------------------------
cleanup() {
    echo "[*] Cleaning up RAM build directory..."
    if mountpoint -q "$RAM_DIR"; then
        sudo fuser -km "$RAM_DIR" 2>/dev/null || true
        sudo umount "$RAM_DIR"
    fi
}
trap cleanup EXIT

# ------------------------------
# Main build function
# ------------------------------
build_pkg() {
    local src="$1"
    local log_file="$LOG_DIR/build.log"

    echo "[*] Starting build: $src"
    mount_ramdisk

    pushd "$RAM_DIR" >/dev/null

    if [[ -d "$src" ]]; then
        cp -r "$src"/* "$RAM_DIR"
        makepkg -scf 2>&1 | tee "$log_file"
    elif [[ "$src" =~ ^https?:// ]]; then
        curl -LO "$src"
        tarball=$(basename "$src")
        tar -xf "$tarball"
        cd "$(basename "$tarball" .tar.*)"
        makepkg -scf 2>&1 | tee "$log_file"
    else
        git clone --depth=1 "https://aur.archlinux.org/$src.git"
        cd "$src"
        makepkg -scf 2>&1 | tee "$log_file"
    fi

    echo "[*] Moving build results to $LOCAL_OUT"
    mv "$RAM_DIR"/*.pkg.tar.* "$LOCAL_OUT" 2>/dev/null || true

    popd >/dev/null
}

# ------------------------------
# Entry point
# ------------------------------
setup_zram

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <pkg_dir|aur_pkg|url>"
    exit 1
fi

build_pkg "$1"

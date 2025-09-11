#!/usr/bin/env bash
# cerebro_rumbuild.sh — build packages entirely in RAM
# Optimized with:
# - Auto ZRAM using all available RAM
# - RAM_DIR auto-mount via tmpfs (/mnt/cerebro_ram_build)
# - Persistent logs in ~/cerebro/log/
# - Auto-copy build results to ~/pkgbuilds

set -euo pipefail

### CONFIGURATION ###
CEREBRO_DIR="$HOME/cerebro"
LOG_DIR="$CEREBRO_DIR/log"
PKG_DST="$HOME/pkgbuilds"
RAM_DIR="/mnt/cerebro_ram_build"
ZRAM_DEV="/dev/zram0"
PKG_SRC="${1:-}"    # first arg = package source (path or AUR dir)

mkdir -p "$CEREBRO_DIR" "$LOG_DIR" "$PKG_DST"

### FUNCTIONS ###
error_exit() {
    echo "[!] Error: $*" >&2
    exit 1
}

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
        sudo swapon -p 100 $ZRAM_DEV
    else
        echo "[*] zram0 already active (size: $((current_size/1024/1024))MB), skipping re-init."
    fi
}

setup_ram_dir() {
    if [[ ! -d "$RAM_DIR" ]]; then
        echo "[*] Creating RAM_DIR: $RAM_DIR"
        sudo mkdir -p "$RAM_DIR"
    fi

    # Check if already mounted
    if ! mountpoint -q "$RAM_DIR"; then
        echo "[*] Mounting tmpfs on $RAM_DIR (size = all available RAM)..."
        sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
        # Optional: add to /etc/fstab for persistent mount
        if ! grep -q "$RAM_DIR" /etc/fstab; then
            echo "tmpfs $RAM_DIR tmpfs defaults,size=100% 0 0" | sudo tee -a /etc/fstab
            echo "[*] Added $RAM_DIR to /etc/fstab"
        fi
    else
        echo "[*] $RAM_DIR already mounted"
    fi
}

check_pkg_src() {
    [[ -z "$PKG_SRC" ]] && error_exit "Usage: $0 <package_source>"
    [[ ! -d "$PKG_SRC" ]] && error_exit "Package source directory not found: $PKG_SRC"
}

build_package() {
    local pkg_name
    pkg_name=$(basename "$PKG_SRC")
    local workdir="$RAM_DIR/$pkg_name"
    local logfile="$LOG_DIR/$pkg_name.log"

    echo "[*] Starting build for: $pkg_name"

    # Fast cleanup, keep directory
    rm -rf "$workdir"/*
    mkdir -p "$workdir"

    cp -r "$PKG_SRC"/* "$workdir"
    cd "$workdir"

    echo "===== Build $(date '+%F %T') =====" | tee -a "$logfile"
    if makepkg -sric --noconfirm --clean > >(tee -a "$logfile") 2>&1; then
        echo "[+] Build & install successful!" | tee -a "$logfile"

        shopt -s nullglob
        for f in ./*.pkg.tar.lz4 ./*.src.tar.zst; do
            cp -v "$f" "$PKG_DST/" | tee -a "$logfile"
        done
        echo "[+] Saved results to $PKG_DST/" | tee -a "$logfile"
    else
        echo "[!] Build failed, see $logfile" | tee -a "$logfile"
        return 1
    fi
}

### MAIN ###
setup_zram
setup_ram_dir
check_pkg_src
build_package

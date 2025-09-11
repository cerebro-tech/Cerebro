#!/usr/bin/env bash
#
# ram_build.sh — build Arch Linux packages entirely in RAM
# Optimized version with Variant B logging:
#  - Single log per package in ~/cerebro/log/<pkg>.log
#  - Appends build date/time inside log
#  - $RAM_DIR persistent, fast workdir cleanup
#  - Auto-install + copy results to ~/pkgbuilds
#  - ZRAM uses all available RAM dynamically

set -euo pipefail

### CONFIGURATION ###
CEREBRO_DIR="$HOME/cerebro"
LOG_DIR="$CEREBRO_DIR/log"
PKG_DST="$HOME/pkgbuilds"
RAM_DIR="/mnt/ram_build"
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
        echo "[*] zram0 not found, loading module..."
        sudo modprobe zram
    fi

    local current_size
    current_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)

    if [[ "$current_size" -eq 0 ]]; then
        # Use all available RAM for ZRAM
        MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
        echo "[*] Initializing zram0 with ${MEM_MB}MB (all available RAM)..."
        echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize > /dev/null
        sudo mkswap $ZRAM_DEV
        sudo swapon -p 100 $ZRAM_DEV
    else
        echo "[*] zram0 already active (size: $((current_size/1024/1024))MB), skipping re-init."
    fi
}

check_ram_dir() {
    if [[ ! -d "$RAM_DIR" ]]; then
        error_exit "RAM_DIR ($RAM_DIR) does not exist. Create it and mount tmpfs via /etc/fstab."
    fi
    if [[ ! -w "$RAM_DIR" ]]; then
        error_exit "RAM_DIR ($RAM_DIR) is not writable by user $USER."
    fi
}

build_package() {
    [[ -z "$PKG_SRC" ]] && error_exit "Usage: $0 <package_source>"
    local pkg_name
    pkg_name=$(basename "$PKG_SRC")
    local workdir="$RAM_DIR/$pkg_name"
    local logfile="$LOG_DIR/$pkg_name.log"

    echo "[*] Starting build for: $pkg_name"

    # Fast workdir cleanup (keep dir, remove contents)
    rm -rf "$workdir"/*
    mkdir -p "$workdir"

    cp -r "$PKG_SRC"/* "$workdir"
    cd "$workdir"

    echo "===== Build $(date '+%F %T') =====" | tee -a "$logfile"
    if makepkg -sric --noconfirm --clean > >(tee -a "$logfile") 2>&1; then
        echo "[+] Build & install successful!" | tee -a "$logfile"

        # Copy resulting packages to persistent storage
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
check_ram_dir
build_package

#!/usr/bin/env bash
# cbro_build — universal RAM build helper
# Features:
# - Build in RAM using tmpfs (/mnt/cerebro_ram_build)
# - Auto ZRAM using all available RAM
# - Persistent logs in ~/cerebro/log/
# - Auto-copy build results to ~/pkgbuilds
# - Can build local directories, AUR packages, or URLs

set -euo pipefail

### CONFIGURATION ###
CEREBRO_DIR="$HOME/cerebro"
LOG_DIR="$CEREBRO_DIR/log"
PKG_DST="$HOME/pkgbuilds"
RAM_DIR="/mnt/cerebro_ram_build"
ZRAM_DEV="/dev/zram0"

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

    if ! mountpoint -q "$RAM_DIR"; then
        echo "[*] Mounting tmpfs on $RAM_DIR (size = all available RAM)..."
        sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
        if ! grep -q "$RAM_DIR" /etc/fstab; then
            echo "tmpfs $RAM_DIR tmpfs defaults,size=100% 0 0" | sudo tee -a /etc/fstab
            echo "[*] Added $RAM_DIR to /etc/fstab"
        fi
    else
        echo "[*] $RAM_DIR already mounted"
    fi
}

fetch_pkg_src() {
    local src="$1"
    if [[ -d "$src" ]]; then
        PKG_SRC="$src"
    elif [[ "$src" =~ ^https?:// ]]; then
        # URL download into RAM_DIR
        local filename
        filename=$(basename "$src")
        PKG_SRC="$RAM_DIR/$filename"
        echo "[*] Downloading $src to $PKG_SRC..."
        curl -L "$src" -o "$PKG_SRC"
        # Extract if tarball
        if [[ "$PKG_SRC" =~ \.tar\.(gz|xz|bz2|zst)$ ]]; then
            mkdir -p "$RAM_DIR/build"
            tar -xf "$PKG_SRC" -C "$RAM_DIR/build"
            PKG_SRC=$(find "$RAM_DIR/build" -mindepth 1 -maxdepth 1 -type d | head -n1)
        fi
    else
        # Assume AUR package
        PKG_SRC="$RAM_DIR/$src"
        if [[ ! -d "$PKG_SRC" ]]; then
            echo "[*] Cloning AUR package $src into $PKG_SRC..."
            git clone "https://aur.archlinux.org/$src.git" "$PKG_SRC"
        fi
    fi

    [[ -d "$PKG_SRC" ]] || error_exit "Package source not found: $PKG_SRC"
}

build_package() {
    local pkg_name
    pkg_name=$(basename "$PKG_SRC")
    local workdir="$RAM_DIR/$pkg_name-build"
    local logfile="$LOG_DIR/$pkg_name.log"

    echo "[*] Starting build for: $pkg_name"

    rm -rf "$workdir"
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
if [[ $# -lt 1 ]]; then
    error_exit "Usage: $0 <package_name|directory|URL>"
fi

setup_zram
setup_ram_dir
fetch_pkg_src "$1"
build_package

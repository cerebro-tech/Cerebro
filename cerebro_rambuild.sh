#!/usr/bin/env bash
# cerebro build script (cbro)

set -euo pipefail

CEREBRO_DIR="/mnt/cerebro"
CACHE_DIR="/var/cache/cerebro"
LOG_DIR="$HOME/cerebro/log"
ZRAM_DEV="/dev/zram0"

mkdir -p "$CACHE_DIR/aur" "$LOG_DIR"

# ------------------------------
# Dependency check
# ------------------------------
install_missing_deps() {
    local deps=(base-devel git binutils gcc make fakeroot)
    for dep in "${deps[@]}"; do
        echo "[*] Checking dependency: $dep"
    done
    sudo pacman -S --needed --noconfirm "${deps[@]}"
}

# ------------------------------
# ZRAM setup
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
        sudo swapon -p 100 $ZRAM_DEV
    else
        echo "[*] zram0 already active (size: $((current_size/1024/1024))MB), skipping re-init."
    fi
}

cleanup_zram() {
    if [[ -b $ZRAM_DEV ]]; then
        echo "[*] Cleaning up ZRAM..."
        sudo swapoff "$ZRAM_DEV" || true
        sudo rmmod zram || true
    fi
}

# ------------------------------
# RAM tmpfs handling
# ------------------------------
mount_tmpfs() {
    echo "[*] Mounting tmpfs on $CEREBRO_DIR ..."
    sudo mount -t tmpfs -o size=100% tmpfs "$CEREBRO_DIR"
    mkdir -p "$CEREBRO_DIR/build"
}

umount_tmpfs() {
    echo "[*] Cleaning RAM build dir..."
    sudo fuser -k "$CEREBRO_DIR" || true
    sync
    sudo umount -l "$CEREBRO_DIR" || true
}

# ------------------------------
# Build package
# ------------------------------
build_package() {
    local pkg="$1"
    local ts
    ts=$(date +"%Y%m%d_%H%M%S")
    local logfile="$LOG_DIR/build_${pkg}_${ts}.log"

    echo "[*] Logging to $logfile"

    echo "[*] Cloning AUR repo: $pkg ..."
    rm -rf "$CACHE_DIR/aur/$pkg"
    git clone "https://aur.archlinux.org/${pkg}.git" "$CACHE_DIR/aur/$pkg" &>>"$logfile"

    cp -r "$CACHE_DIR/aur/$pkg" "$CEREBRO_DIR/build/$pkg"

    cd "$CEREBRO_DIR/build/$pkg"
    echo "[*] Building $pkg ..."
    makepkg -sric --noconfirm &>>"$logfile" || {
        echo "[!] Build failed. Saving copy to $CACHE_DIR/failed/$pkg ..."
        mkdir -p "$CACHE_DIR/failed"
        cp -r "$CEREBRO_DIR/build/$pkg" "$CACHE_DIR/failed/${pkg}_${ts}"
        return 1
    }
}

# ------------------------------
# Main
# ------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <package>"
        exit 1
    fi

    local pkg="$1"

    install_missing_deps
    setup_zram
    mount_tmpfs

    trap 'echo "[!] Aborting..."; umount_tmpfs; cleanup_zram' EXIT

    build_package "$pkg"

    umount_tmpfs
    cleanup_zram

    echo "[*] Done."
}

main "$@"

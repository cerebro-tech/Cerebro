#!/usr/bin/env bash
# cerebro_rambuild.sh — build Arch/AUR packages in RAM with tmpfs + zram
# Requirements (install manually once): base-devel, git, wget, pacman, zram module
# Usage:
#   cbro ~/Downloads/mypkg      # build from local dir
#   cbro paru                   # build from AUR
#   cbro https://example.com/pkg.tar.zst  # build from URL

set -euo pipefail

RAM_DIR="/mnt/cerebro"
CACHE_DIR="/var/cache/cerebro"
LOG_DIR="$HOME/cerebro/log"
ZRAM_DEV="/dev/zram0"
PKG_SRC="${1:-}"

mkdir -p "$CACHE_DIR"/aur "$LOG_DIR"

error_exit() {
    echo "[!] $1" >&2
    cleanup
    exit 1
}

cleanup() {
    echo "[*] Cleaning RAM build dir..."
    fuser -k "$RAM_DIR" 2>/dev/null || true
    umount "$RAM_DIR" 2>/dev/null || true
}

setup_tmpfs() {
    echo "[*] Mounting tmpfs on $RAM_DIR ..."
    sudo mkdir -p "$RAM_DIR"
    sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
}

setup_zram() {
    echo "[*] Resetting zram..."
    if [[ -b $ZRAM_DEV ]]; then
        sudo swapoff "$ZRAM_DEV" 2>/dev/null || true
        echo 1 | sudo tee /sys/block/zram0/reset >/dev/null
    else
        sudo modprobe zram
    fi

    MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    echo "[*] Initializing zram0 with ${MEM_MB}MB (all available RAM)..."
    echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize >/dev/null
    sudo mkswap "$ZRAM_DEV"
    sudo swapon -p 100 "$ZRAM_DEV"
}

prepare_pkg_src() {
    if [[ -d "$PKG_SRC" ]]; then
        SRC_DIR="$PKG_SRC"
    elif [[ "$PKG_SRC" =~ ^https?:// ]]; then
        SRC_DIR="$RAM_DIR/$(basename "$PKG_SRC" .tar.*)"
        mkdir -p "$SRC_DIR"
        wget -c "$PKG_SRC" -O "$SRC_DIR/source.tar.zst"
        cd "$SRC_DIR"
        tar -xf source.tar.zst
    else
        if pacman -Si "$PKG_SRC" &>/dev/null; then
            echo "[*] '$PKG_SRC' is in official repos, using asp..."
            SRC_DIR="$RAM_DIR/$PKG_SRC"
            mkdir -p "$SRC_DIR"
            asp export "$PKG_SRC" -d "$SRC_DIR"
        else
            echo "[*] '$PKG_SRC' is in AUR, cloning..."
            SRC_DIR="$RAM_DIR/$PKG_SRC"
            if ! git clone "https://aur.archlinux.org/$PKG_SRC.git" "$SRC_DIR"; then
                error_exit "Package '$PKG_SRC' not found in AUR or repos."
            fi
        fi
    fi
}


build_pkg() {
    cd "$SRC_DIR"
    LOG_FILE="$LOG_DIR/build_${PKG_SRC}_$(date +%Y%m%d_%H%M%S).log"
    echo "[*] Logging to $LOG_FILE"
    makepkg -sic --noconfirm --needed 2>&1 | tee "$LOG_FILE"
}

main() {
    [[ -z "$PKG_SRC" ]] && error_exit "Usage: cbro <dir|aur-pkg|url>"

    trap cleanup EXIT

    setup_tmpfs
    setup_zram
    prepare_pkg_src
    build_pkg
    echo "[*] Build complete: $PKG_SRC"
}

main "$@"

#!/usr/bin/env bash
# cerebro_rambuild.sh - Optimized RAM build script for Arch Linux
# Usage examples:
#   cbro_build ~/Downloads/mypkg
#   cbro_build paru
#   cbro_build https://example.com/somepkg.tar.zst
#
# Aliased as: cbro_build

set -euo pipefail

# Paths
RAM_DIR="/mnt/cerebro"
CACHE_DIR="/var/cache/cerebro"
BUILD_DIR="$RAM_DIR/build"
LOG_DIR="$HOME/cerebro/log"
PKG_DIR="$CACHE_DIR/pkg"
SRC_DIR="$CACHE_DIR/src"

# Devices
ZRAM_DEV="/dev/zram0"

# Flags
KEEP_BUILD=0

# Functions
setup_dirs() {
    sudo mkdir -p "$RAM_DIR" "$CACHE_DIR" "$BUILD_DIR" "$LOG_DIR" "$PKG_DIR" "$SRC_DIR"
    sudo chown -R "$USER":"$USER" "$CACHE_DIR" "$LOG_DIR"

    # mount tmpfs for RAM builds if not already mounted
    if ! mountpoint -q "$RAM_DIR"; then
        echo "[*] Mounting tmpfs on $RAM_DIR ..."
        sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
    fi
}

setup_zram() {
    if [[ ! -b $ZRAM_DEV ]]; then
        echo "[*] Loading zram module..."
        sudo modprobe zram
    fi

    local current_size
    current_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)

    if [[ "$current_size" -eq 0 ]]; then
        MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
        echo "[*] Initializing zram0 with ${MEM_MB}MB (all available RAM)..."
        echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize > /dev/null
        sudo mkswap $ZRAM_DEV
        sudo swapon -p 100 $ZRAM_DEV
    else
        echo "[*] zram0 already active (size: $((current_size/1024/1024))MB), skipping re-init."
    fi
}

safe_umount() {
    if mountpoint -q "$RAM_DIR"; then
        echo "[*] Cleaning RAM build dir..."
        if [[ $KEEP_BUILD -eq 0 ]]; then
            sudo fuser -k "$RAM_DIR" || true
            sudo umount "$RAM_DIR" || true
        else
            echo "[*] --keep enabled, leaving $RAM_DIR mounted."
        fi
    fi
}

trap safe_umount EXIT

build_pkg() {
    local src="$1"
    local pkgname
    pkgname=$(basename "$src" .git)

    local build_log="$LOG_DIR/build_${pkgname}_$(date +'%Y%m%d_%H%M%S').log"
    echo "[*] Logging to $build_log"

    if [[ -d "$BUILD_DIR/$pkgname" ]]; then
        echo "[*] Cleaning old build dir: $BUILD_DIR/$pkgname"
        rm -rf "$BUILD_DIR/$pkgname"
    fi
    mkdir -p "$BUILD_DIR/$pkgname"
    cd "$BUILD_DIR/$pkgname"

    if [[ -d "$CACHE_DIR/aur/$pkgname/.git" ]]; then
        echo "[*] Updating cached repo for $pkgname ..."
        git -C "$CACHE_DIR/aur/$pkgname" pull --ff-only || true
        cp -r "$CACHE_DIR/aur/$pkgname"/* .
    elif [[ "$src" =~ ^https?:// ]]; then
        echo "[*] Downloading package from $src ..."
        curl -L "$src" -o "$pkgname.pkg.tar.zst"
        sudo pacman -U "$pkgname.pkg.tar.zst" --noconfirm |& tee "$build_log"
        return
    elif [[ -d "$src" ]]; then
        echo "[*] Building local directory: $src ..."
        cp -r "$src"/* .
    else
        echo "[*] Cloning AUR repo: $pkgname ..."
        mkdir -p "$CACHE_DIR/aur"
        git clone "https://aur.archlinux.org/$pkgname.git" "$CACHE_DIR/aur/$pkgname"
        cp -r "$CACHE_DIR/aur/$pkgname"/* .
    fi

    echo "[*] Running makepkg..."
    makepkg -s --noconfirm --clean --cleanbuild --log --config /etc/makepkg.conf \
        PKGDEST="$PKG_DIR" SRCDEST="$SRC_DIR" |& tee "$build_log"

    local built_pkg
    built_pkg=$(find "$PKG_DIR" -type f -name "${pkgname}-*.pkg.tar.*" -print -quit)
    if [[ -n "$built_pkg" ]]; then
        echo "[*] Installing package: $built_pkg"
        sudo pacman -U --noconfirm "$built_pkg" |& tee -a "$build_log"
    else
        echo "[!] Build failed, keeping build dir for debugging."
        KEEP_BUILD=1
        return 1
    fi

    echo "[*] Build completed successfully."
}

# Main
if [[ "${1:-}" == "--keep" ]]; then
    KEEP_BUILD=1
    shift
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--keep] <package|path|url>"
    exit 1
fi

setup_dirs
setup_zram
build_pkg "$1"

#!/usr/bin/env bash
#
# Cerebro RAM Build Script (cbro)
# Optimized temporary RAM builds with ZRAM and tmpfs
#

set -euo pipefail

# ===========================
# Config
# ===========================
CBRO_MNT="/mnt/cerebro"
CBRO_CACHE="/var/cache/cerebro"
CBRO_LOG_DIR="$HOME/cerebro/log"
ZRAM_DEV="/dev/zram0"

# ===========================
# Helper functions
# ===========================
timestamp() {
    date +"%Y%m%d_%H%M%S"
}

log_msg() {
    echo "[*] $*"
}

install_missing_deps() {
    local deps=("$@")
    for dep in "${deps[@]}"; do
        if ! pacman -Qi "$dep" &>/dev/null; then
            log_msg "Installing missing dependency: $dep"
            sudo pacman -S --needed --noconfirm "$dep"
        else
            log_msg "Dependency $dep already installed, skipping."
        fi
    done
}

setup_zram() {
    if [[ ! -b $ZRAM_DEV ]]; then
        log_msg "Loading zram module..."
        sudo modprobe zram
    fi

    local current_size
    current_size=$(cat /sys/block/zram0/disksize 2>/dev/null || echo 0)

    if [[ "$current_size" -eq 0 ]]; then
        MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
        log_msg "Initializing zram0 with ${MEM_MB}MB (all available RAM)..."
        echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize > /dev/null
        sudo mkswap $ZRAM_DEV
        sudo swapon -p 100 $ZRAM_DEV
    else
        log_msg "zram0 already active (size: $((current_size/1024/1024))MB), skipping re-init."
    fi
}

cleanup_zram() {
    if [[ -b $ZRAM_DEV ]]; then
        log_msg "Cleaning up ZRAM..."
        sudo swapoff "$ZRAM_DEV" || true
        sudo rmmod zram || true
    fi
}

safe_umount() {
    local target="$1"
    if mountpoint -q "$target"; then
        log_msg "Unmounting $target..."
        sync
        sudo fuser -k "$target" || true
        sudo umount -l "$target" || true
    fi
}

# ===========================
# Main build
# ===========================
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: cbro <pkgname>"
        exit 1
    fi

    local pkgname="$1"
    local log_file="$CBRO_LOG_DIR/build_${pkgname}_$(timestamp).log"

    mkdir -p "$CBRO_LOG_DIR"

    log_msg "Mounting tmpfs on $CBRO_MNT ..."
    sudo mkdir -p "$CBRO_MNT"
    sudo mount -t tmpfs -o size=100% tmpfs "$CBRO_MNT"

    log_msg "Setting up ZRAM..."
    setup_zram

    log_msg "Ensuring build cache exists..."
    sudo mkdir -p "$CBRO_CACHE/aur"

    log_msg "Logging to $log_file"

    # Install dependencies (skip if already installed)
    install_missing_deps base-devel git rust

    # Clone AUR package
    local aur_dir="$CBRO_CACHE/aur/$pkgname"
    if [[ ! -d "$aur_dir/.git" ]]; then
        log_msg "Cloning AUR repo: $pkgname ..."
        git clone "https://aur.archlinux.org/${pkgname}.git" "$aur_dir" >>"$log_file" 2>&1 || {
            echo "[ERROR] Failed to clone AUR package $pkgname" | tee -a "$log_file"
            safe_umount "$CBRO_MNT"
            cleanup_zram
            exit 1
        }
    else
        log_msg "Updating existing AUR repo: $pkgname ..."
        (cd "$aur_dir" && git pull) >>"$log_file" 2>&1 || true
    fi

    # Copy to RAM build dir
    cp -r "$aur_dir" "$CBRO_MNT/$pkgname"

    # Build
    pushd "$CBRO_MNT/$pkgname" >/dev/null
    log_msg "Building package $pkgname ..."
    makepkg -sric --noconfirm >>"$log_file" 2>&1
    popd >/dev/null

    log_msg "Build complete: $pkgname"

    # Cleanup
    log_msg "Cleaning RAM build dir..."
    rm -rf "$CBRO_MNT/$pkgname"

    safe_umount "$CBRO_MNT"
    cleanup_zram

    log_msg "Done."
}

main "$@"

#!/usr/bin/env bash
# cerebro_rambuild.sh – Build packages in RAM with ZRAM + tmpfs (auto-mount/unmount)

set -euo pipefail

RAMDISK="/mnt/cerebro_ram_build"
LOGDIR="$HOME/cerebro/log"
PKGDEST="$HOME/cerebro/pkg"
ZRAM_DEV="/dev/zram0"

mkdir -p "$LOGDIR" "$PKGDEST"

# --- Setup ZRAM ---
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

# --- Setup RAM disk ---
mount_ramdisk() {
    sudo mkdir -p "$RAMDISK"
    if ! mountpoint -q "$RAMDISK"; then
        echo "[*] Mounting tmpfs on $RAMDISK"
        sudo mount -t tmpfs -o size=100% tmpfs "$RAMDISK"
    fi
}

unmount_ramdisk() {
    if mountpoint -q "$RAMDISK"; then
        echo "[*] Unmounting $RAMDISK"
        sudo umount "$RAMDISK"
    fi
}

# Auto-cleanup on exit
trap unmount_ramdisk EXIT

# --- Build package ---
build_pkg() {
    local src="$1"
    local builddir="$RAMDISK/build"
    rm -rf "$builddir"
    mkdir -p "$builddir"
    cd "$builddir"

    if [[ "$src" =~ ^https?:// ]]; then
        echo "[+] Downloading source from $src"
        curl -LO "$src"
        if [[ "$src" =~ \.tar\.(gz|xz|zst)$ ]]; then
            tar -xf "$(basename "$src")"
            cd "$(find . -maxdepth 1 -type d | tail -n 1)"
        fi
    elif [[ -d "$src" ]]; then
        echo "[+] Copying local source: $src"
        cp -r "$src"/* .
    else
        echo "[+] Cloning AUR package: $src"
        git clone "https://aur.archlinux.org/${src}.git"
        cd "$src"
    fi

    local log_file="$LOGDIR/$(basename "$src").log"
    echo "===== Build $(date) =====" | tee "$log_file"
    if makepkg -sric --noconfirm --log >>"$log_file" 2>&1; then
        mv ./*.pkg.tar.* "$PKGDEST"/ || true
        echo "[+] Package built and moved to $PKGDEST"
    else
        echo "[!] Build failed, see log: $log_file"
        exit 1
    fi
}

# --- Main ---
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <pkgname | localdir | url>"
    exit 1
fi

setup_zram
mount_ramdisk
build_pkg "$1"

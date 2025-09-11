#!/usr/bin/env bash
# cbro — universal RAM build script (optimized)
#
# Requirements (install manually if missing):
#   base-devel git wget zram kernel module
#
# Features:
# - Always fresh tmpfs build dir (/mnt/cerebro)
# - Always reset ZRAM each run
# - Persistent logs in ~/cerebro/log/
# - Copy results to ~/pkgbuilds/
# - Works with local dir, AUR package, or URL

set -euo pipefail

### CONFIGURATION ###
CEREBRO_DIR="$HOME/cerebro"
LOG_DIR="$CEREBRO_DIR/log"
PKG_DST="$HOME/pkgbuilds"
RAM_DIR="/mnt/cerebro"
ZRAM_DEV="/dev/zram0"
PKG_SRC="${1:-}"    # local path, AUR package name, or URL

mkdir -p "$CEREBRO_DIR" "$LOG_DIR" "$PKG_DST"

### FUNCTIONS ###

error_exit() {
    echo "[!] Error: $*" >&2
    exit 1
}

# Reset ZRAM fresh every run
setup_zram() {
    if [[ -b $ZRAM_DEV ]]; then
        echo "[*] Resetting existing ZRAM..."
        sudo swapoff "$ZRAM_DEV" 2>/dev/null || true
        echo 1 | sudo tee /sys/block/zram0/reset >/dev/null
    else
        echo "[*] Loading zram module..."
        sudo modprobe zram
    fi

    MEM_MB=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    echo "[*] Initializing zram0 with ${MEM_MB}MB..."
    echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize >/dev/null
    sudo mkswap "$ZRAM_DEV"
    sudo swapon -p 100 "$ZRAM_DEV"
}

# Mount tmpfs RAM_DIR
setup_ram_dir() {
    sudo mkdir -p "$RAM_DIR"
    if mountpoint -q "$RAM_DIR"; then
        echo "[*] Cleaning existing RAM_DIR..."
        sudo umount -l "$RAM_DIR"
    fi
    echo "[*] Mounting tmpfs on $RAM_DIR..."
    sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
}

# Copy results safely
safe_copy_results() {
    local workdir="$1"
    shopt -s nullglob
    for f in "$workdir"/*.{pkg.tar.lz4,src.tar.zst}; do
        cp -v "$f" "$PKG_DST/"
    done
}

# Detect source type
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
        SRC_DIR="$RAM_DIR/$PKG_SRC"
        if [[ ! -d "$SRC_DIR" ]]; then
            git clone "https://aur.archlinux.org/$PKG_SRC.git" "$SRC_DIR"
        fi
    fi
}

# Build package
build_package() {
    local workdir="$RAM_DIR/$(basename "$SRC_DIR")"
    local logfile="$LOG_DIR/build_$(basename "$SRC_DIR")_$(date '+%Y%m%d_%H%M%S').log"

    echo "[*] Starting build: $(basename "$SRC_DIR")"
    echo "[*] Logging to $logfile"

    rm -rf "$workdir"
    cp -r "$SRC_DIR" "$workdir"
    cd "$workdir"

    echo "===== Build $(date '+%F %T') =====" | tee -a "$logfile"

    if makepkg -sric --noconfirm --clean > >(tee -a "$logfile") 2>&1; then
        echo "[+] Build & install successful!" | tee -a "$logfile"
        safe_copy_results "$workdir"
        echo "[+] Results saved to $PKG_DST/" | tee -a "$logfile"
    else
        echo "[!] Build failed, see $logfile" | tee -a "$logfile"
        return 1
    fi
}

# Cleanup RAM dir
cleanup_ram_dir() {
    if mountpoint -q "$RAM_DIR"; then
        echo "[*] Cleaning up RAM_DIR..."
        sudo umount -l "$RAM_DIR" || echo "[!] Could not unmount $RAM_DIR"
    fi
}

### MAIN ###

setup_zram
setup_ram_dir
prepare_pkg_src
build_package
cleanup_ram_dir

echo "[*] Build process finished."

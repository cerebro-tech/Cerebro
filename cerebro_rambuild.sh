#!/usr/bin/env bash
# cerebro_rambuild.sh — universal RAM package builder with auto-dependencies
# Alias: cbro
# Features:
# - Auto tmpfs mount/unmount (/mnt/cerebro)
# - Auto ZRAM (all available RAM) and cleanup after build
# - Automatic installation of missing dependencies
# - Handles AUR, local PKGBUILDs, repo packages, URLs
# - Persistent logs ~/cerebro/log/
# - Cache in /var/cache/cerebro
# - Results stored in ~/pkgbuilds
# - Optional --keep to preserve build dir

set -euo pipefail

### CONFIG ###
CEREBRO_DIR="$HOME/cerebro"
LOG_DIR="$CEREBRO_DIR/log"
PKG_DIR="$HOME/pkgbuilds"
RAM_DIR="/mnt/cerebro"
CACHE_DIR="/var/cache/cerebro"
SRC_DIR="$CACHE_DIR/src"
AUR_CACHE="$CACHE_DIR/aur"
ZRAM_DEV="/dev/zram0"
KEEP_BUILD=0

# Parse --keep
if [[ "${@: -1}" == "--keep" ]]; then
    KEEP_BUILD=1
    PKG_SRC="${@:1:$#-1}"
else
    PKG_SRC="${1:-}"
fi

mkdir -p "$CEREBRO_DIR" "$LOG_DIR" "$PKG_DIR" "$SRC_DIR" "$AUR_CACHE"

### FUNCTIONS ###
error_exit() {
    echo "[!] $*" >&2
    exit 1
}

install_missing_deps() {
    local deps=("$@")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "[*] Installing missing dependency: $dep"
            sudo pacman -S --noconfirm "$dep"
        fi
    done
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
        echo "$((MEM_MB*1024*1024))" | sudo tee /sys/block/zram0/disksize >/dev/null
        sudo mkswap $ZRAM_DEV
        sudo swapon -p 100 $ZRAM_DEV
    else
        echo "[*] zram0 already active (size: $((current_size/1024/1024))MB)"
    fi
}

cleanup_zram() {
    if [[ -b $ZRAM_DEV ]]; then
        echo "[*] Cleaning up ZRAM..."
        sudo swapoff $ZRAM_DEV || true
        echo 0 | sudo tee /sys/block/zram0/disksize >/dev/null || true
    fi
}

mount_ram() {
    if ! mountpoint -q "$RAM_DIR"; then
        echo "[*] Mounting tmpfs on $RAM_DIR ..."
        sudo mkdir -p "$RAM_DIR"
        sudo mount -t tmpfs -o size=100% tmpfs "$RAM_DIR"
    fi
}

safe_umount() {
    if mountpoint -q "$RAM_DIR"; then
        echo "[*] Cleaning RAM build dir..."
        cd ~ || true
        if [[ $KEEP_BUILD -eq 0 ]]; then
            sudo fuser -k "$RAM_DIR" || true
            sudo umount "$RAM_DIR" || true
        else
            echo "[*] --keep enabled, leaving $RAM_DIR mounted."
        fi
    fi
}

build_pkg() {
    local src="$1"
    [[ -z "$src" ]] && error_exit "Usage: $0 <package_source>"

    local pkgname
    pkgname=$(basename "$src" .git)
    local workdir="$RAM_DIR/$pkgname"
    local logfile="$LOG_DIR/build_${pkgname}_$(date +'%Y%m%d_%H%M%S').log"
    echo "[*] Logging to $logfile"

    # 1. Install core build tools if missing
    install_missing_deps git base-devel curl wget pkgconf openssl rust cargo

    # 2. Official repo
    if pacman -Si "$pkgname" &>/dev/null; then
        echo "[*] $pkgname is in official repos, installing..."
        sudo pacman -S --noconfirm "$pkgname" |& tee "$logfile"
        return
    fi

    # 3. Reset build dir
    rm -rf "$workdir"
    mkdir -p "$workdir"
    cd "$workdir"

    # 4. Handle source
    if [[ -d "$src/.git" ]]; then
        echo "[*] Using local git repo: $src"
        cp -r "$src"/* .
    elif [[ -d "$src" ]]; then
        echo "[*] Using local directory: $src"
        cp -r "$src"/* .
    elif [[ "$src" =~ ^https?:// ]]; then
        echo "[*] Downloading from $src ..."
        curl -L "$src" -o "$pkgname.pkg.tar.zst"
        sudo pacman -U --noconfirm "$pkgname.pkg.tar.zst" |& tee "$logfile"
        return
    else
        # AUR
        if [[ -d "$AUR_CACHE/$pkgname/.git" ]]; then
            echo "[*] Updating cached AUR repo: $pkgname"
            git -C "$AUR_CACHE/$pkgname" pull --ff-only || true
        else
            echo "[*] Cloning AUR repo: $pkgname"
            git clone "https://aur.archlinux.org/$pkgname.git" "$AUR_CACHE/$pkgname"
        fi
        cp -r "$AUR_CACHE/$pkgname"/* .
    fi

    # 5. OpenSSL for Rust
    if command -v cargo &>/dev/null; then
        if pkg-config --exists openssl; then
            export OPENSSL_DIR=$(pkg-config --variable=prefix openssl)
            echo "[*] OPENSSL_DIR set to $OPENSSL_DIR for Rust builds"
        else
            echo "[!] OpenSSL not found via pkg-config, using default /usr"
            export OPENSSL_DIR="/usr"
        fi
    fi

    # 6. Build
    echo "[*] Building $pkgname ..."
    if makepkg -s --noconfirm --clean --cleanbuild \
        PKGDEST="$PKG_DIR" SRCDEST="$SRC_DIR" |& tee "$logfile"; then
        local built_pkg
        built_pkg=$(find "$PKG_DIR" -type f -name "${pkgname}-*.pkg.tar.*" -print -quit)
        if [[ -n "$built_pkg" ]]; then
            echo "[*] Installing $built_pkg"
            sudo pacman -U --noconfirm "$built_pkg" |& tee -a "$logfile"
        fi
    else
        echo "[!] Build failed, keeping workdir"
        KEEP_BUILD=1
        return 1
    fi
}

### MAIN ###
trap 'safe_umount; cleanup_zram' EXIT
setup_zram
mount_ram
build_pkg "$PKG_SRC"

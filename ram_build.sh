#!/usr/bin/env bash
# ram_build.sh - build packages fully in RAM for speed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
# Use ~1/6 of RAM as safe max build space
BUILD_RAM_MB=$((RAM_MB / 6))
[ "$BUILD_RAM_MB" -lt 512 ] && BUILD_RAM_MB=512  # minimum 512MB

BUILD_DIR="/dev/shm/ram_build"
mkdir -p "$BUILD_DIR"

log_file="$LOG_DIR/ram_build-paru.log"

# --- Helper to copy source ---
fetch_source() {
    src_type="$1"
    src_val="$2"
    case "$src_type" in
        git)
            echo "[*] Cloning git repo $src_val..."
            git clone --depth 1 "$src_val" "$BUILD_DIR/src"
            ;;
        tar)
            echo "[*] Downloading tarball $src_val..."
            curl -L "$src_val" -o "$BUILD_DIR/src.tar.gz"
            mkdir -p "$BUILD_DIR/src"
            tar -xzf "$BUILD_DIR/src.tar.gz" -C "$BUILD_DIR/src" --strip-components=1
            ;;
        pkg)
            echo "[*] Copying local package $src_val..."
            cp -r "$src_val" "$BUILD_DIR/src"
            ;;
        *)
            echo "[!] Unknown source type: $src_type" >&2
            exit 1
            ;;
    esac
}

# --- Main build function ---
build_package() {
    cd "$BUILD_DIR/src"
    echo "[*] Building in RAM at $BUILD_DIR..."
    makepkg -si --noconfirm | tee -a "$log_file"
}

# --- Usage check ---
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <git|tar|pkg> <source> [extra makepkg args]"
    exit 1
fi

SRC_TYPE="$1"
SRC_VAL="$2"
shift 2
EXTRA_ARGS="$@"

# --- Run ---
rm -rf "$BUILD_DIR/src"
fetch_source "$SRC_TYPE" "$SRC_VAL"
cd "$BUILD_DIR/src"

echo "[*] Starting build..."
makepkg -si --noconfirm $EXTRA_ARGS | tee -a "$log_file"

echo "[*] Cleaning RAM build dir..."
rm -rf "$BUILD_DIR"

echo "[*] Build finished. Log saved at $log_file"

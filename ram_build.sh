#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
# Build any package in RAM using ZRAM or /tmp, auto-clean after finish

set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

BUILD_LOG="$LOG_DIR/ram_build-paru.log"
PACKAGE="$1"
RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)

# Determine tmpfs size: 80% of RAM, min 1GB, max 32GB
TMPFS_MB=$(( RAM_MB * 80 / 100 ))
[ "$TMPFS_MB" -lt 1024 ] && TMPFS_MB=1024
[ "$TMPFS_MB" -gt 32768 ] && TMPFS_MB=32768

BUILD_DIR="/tmp/ram_build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mount -t tmpfs -o size=${TMPFS_MB}M tmpfs "$BUILD_DIR"

echo "[*] Building package '$PACKAGE' in RAM at $BUILD_DIR"
echo "[*] RAM: ${RAM_MB}MB, TMPFS size: ${TMPFS_MB}MB"
echo "[*] Logs: $BUILD_LOG"

cd "$BUILD_DIR"

# Helper function to cleanup tmpfs
cleanup() {
    echo "[*] Cleaning up RAM build directory..."
    cd /
    umount -l "$BUILD_DIR" || true
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

# Determine package type and build
if [[ "$PACKAGE" =~ \.tar\.gz$|\.tar\.bz2$|\.tar\.xz$ ]]; then
    echo "[*] Detected tarball. Extracting..."
    tar xf "$PACKAGE"
    PKG_DIR=$(find . -maxdepth 1 -type d ! -name tmp* ! -name . -print | head -n1)
    cd "$PKG_DIR"
    echo "[*] Running makepkg..."
    makepkg -si --noconfirm &> "$BUILD_LOG"
elif [[ "$PACKAGE" =~ ^git\+ ]]; then
    REPO="${PACKAGE#git+}"
    echo "[*] Detected git repo: $REPO"
    git clone "$REPO" repo_src &>> "$BUILD_LOG"
    cd repo_src
    if [ -f PKGBUILD ]; then
        echo "[*] Running makepkg for PKGBUILD..."
        makepkg -si --noconfirm &>> "$BUILD_LOG"
    else
        echo "[*] No PKGBUILD found, trying cmake/make..."
        mkdir -p build && cd build
        cmake .. &>> "$BUILD_LOG"
        make -j$(nproc) &>> "$BUILD_LOG"
        sudo make install &>> "$BUILD_LOG"
    fi
else
    # Assume AUR package name
    echo "[*] Building AUR package using paru..."
    "$SCRIPT_DIR/rparu" "$PACKAGE" &> "$BUILD_LOG"
fi

echo "[*] Build finished. Logs stored in $BUILD_LOG"

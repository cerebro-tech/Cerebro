#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <package-name-or-git-dir> [makepkg-args...]"
    exit 1
fi

PKG="$1"
shift
ARGS="$@"

# Detect total RAM in MB
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_MB / 1024))

# Use safe fraction for tmpfs: max 80% RAM, minimum 512MB
if [ "$TOTAL_RAM_MB" -lt 1024 ]; then
    TMPFS_SIZE_MB=$((TOTAL_RAM_MB / 2))
else
    TMPFS_SIZE_MB=$((TOTAL_RAM_MB * 80 / 100))
fi
TMPFS_SIZE_MB=$(( TMPFS_SIZE_MB < 512 ? 512 : TMPFS_SIZE_MB ))

# Create tmpfs for building
BUILD_DIR="/tmp/ram_build_$PKG"
mkdir -p "$BUILD_DIR"
sudo mount -t tmpfs -o size=${TMPFS_SIZE_MB}M tmpfs "$BUILD_DIR"

echo "[*] Building $PKG in RAM ($TMPFS_SIZE_MB MB tmpfs)..."

# Copy source if it's a directory (git clone case)
if [ -d "$PKG" ]; then
    cp -a "$PKG" "$BUILD_DIR/$PKG"
    cd "$BUILD_DIR/$PKG"
else
    cd "$BUILD_DIR"
    # Try downloading from AUR if it's not local directory
    git clone "https://aur.archlinux.org/$PKG.git"
    cd "$PKG"
fi

# Set up log file
LOG_FILE="$LOG_DIR/ram_build-${PKG}.log"
echo "[*] Logging build to $LOG_FILE"

# Backup makepkg.conf and rust.conf if they exist
[ -f /etc/makepkg.conf ] && sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak
[ -f /etc/rust.conf ] && sudo cp /etc/rust.conf /etc/rust.conf.bak

# Apply Cerebro configs if present
[ -f "$HOME/.makepkg.conf" ] && sudo cp "$HOME/.makepkg.conf" /etc/makepkg.conf
[ -f "$HOME/.rust.conf" ] && sudo cp "$HOME/.rust.conf" /etc/rust.conf

# Build package
if command -v makepkg &>/dev/null; then
    makepkg -si $ARGS 2>&1 | tee "$LOG_FILE"
else
    echo "[!] makepkg not found. Install base-devel."
    exit 1
fi

# Cleanup
cd ~
sudo umount "$BUILD_DIR" || true
rm -rf "$BUILD_DIR"

echo "[*] Build completed for $PKG. Log saved in $LOG_FILE."

#!/usr/bin/env bash
# Build any package in RAM

set -euo pipefail
IFS=$'\n\t'

BUILD_DIR="/tmp/ram_build"
LOG_FILE="$BUILD_DIR/ram_build-paru.log"

SRC_URL="$1"
PKG_NAME=$(basename "$SRC_URL" .git)

echo "[*] Building $PKG_NAME in $BUILD_DIR"
rm -rf "$BUILD_DIR/$PKG_NAME"
git clone "$SRC_URL" "$BUILD_DIR/$PKG_NAME"
cd "$BUILD_DIR/$PKG_NAME"

echo "[*] Starting build..."
makepkg -s --noconfirm | tee -a "$LOG_FILE"

echo "[*] Installing package..."
sudo pacman -U --noconfirm *.pkg.tar.zst | tee -a "$LOG_FILE"
echo "[*] Build completed, log: $LOG_FILE"

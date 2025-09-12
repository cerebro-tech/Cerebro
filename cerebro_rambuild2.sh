#!/bin/bash

LOG="$HOME/build.log"
exec > >(tee -a "$LOG") 2>&1

echo "[RAMBUILD] Starting..."

# Allow running manually if inside a PKGBUILD folder
if [[ "$0" != *makepkg* && "$1" != *makepkg* && ! -f ./PKGBUILD ]]; then
  echo "[RAMBUILD] Exiting: not in PKGBUILD directory and not makepkg context"
  exit 1
fi

# === TMPFS CONFIG ===
TMPFS_DIR="$HOME/.cache/rambuild"
[ ! -d "$TMPFS_DIR" ] && mkdir -p "$TMPFS_DIR"

FREE_RAM=$(free -m | awk '/Mem:/ {print int($4*0.9)}')
[ "$FREE_RAM" -gt 58000 ] && FREE_RAM=58000
echo "[RAMBUILD] Free RAM for tmpfs: ${FREE_RAM} MB"

if ! mountpoint -q "$TMPFS_DIR"; then
    echo "[RAMBUILD] Mounting tmpfs..."
    sudo mount -t tmpfs -o size="${FREE_RAM}m",mode=0755,uid=$(id -u),gid=$(id -g),noatime tmpfs "$TMPFS_DIR" || {
        echo "[RAMBUILD] Mount failed"
        exit 1
    }
else
    echo "[RAMBUILD] tmpfs already mounted"
fi

# === COPY SOURCE TO RAM ===
ORIG_DIR="$(pwd -P)"
if [[ "$ORIG_DIR" == "$TMPFS_DIR" ]]; then
  echo "[RAMBUILD] Already in tmpfs, skipping copy"
else
  echo "[RAMBUILD] Copying source from: $ORIG_DIR"
  cp -a "$ORIG_DIR"/* "$TMPFS_DIR"/
fi

cd "$TMPFS_DIR" || {
    echo "[RAMBUILD] Failed to enter tmpfs directory"
    sudo umount "$TMPFS_DIR"
    exit 1
}

# === PARALLEL FLAGS ===
export MAKEFLAGS="-j$(nproc)"
export NINJAFLAGS="-j$(nproc)"

# === CMAKE GENERATOR FALLBACK ===
if command -v cmake &>/dev/null && command -v ninja &>/dev/null; then
    mkdir -p "$TMPFS_DIR/test-cmake"
    pushd "$TMPFS_DIR/test-cmake" >/dev/null
    echo 'cmake_minimum_required(VERSION 3.10)
project(TestNinja)
add_executable(dummy main.c)' > CMakeLists.txt
    echo 'int main() { return 0; }' > main.c
    cmake -G Ninja . &>/dev/null
    if [[ $? -eq 0 ]]; then
        export CMAKE_GENERATOR="Ninja"
        echo "[RAMBUILD] Using CMAKE_GENERATOR=Ninja"
    else
        export CMAKE_GENERATOR="Unix Makefiles"
        echo "[RAMBUILD] Falling back to CMAKE_GENERATOR=Unix Makefiles"
    fi
    popd >/dev/null
    rm -rf "$TMPFS_DIR/test-cmake"
else
    export CMAKE_GENERATOR="Unix Makefiles"
fi

# === RUN MAKEPKG ===
echo "[RAMBUILD] Building package..."
if ! /usr/bin/makepkg "$@"; then
    echo "[RAMBUILD] makepkg failed, cleaning up"
    sudo umount "$TMPFS_DIR"
    exit 1
fi

# === FIND BUILT PACKAGE ===
PACKAGE_FILE=$(find "$TMPFS_DIR" -type f -name "*.pkg.tar.*" | head -n 1)
if [[ -z "$PACKAGE_FILE" ]]; then
    echo "[RAMBUILD] No package built!"
    sudo umount "$TMPFS_DIR"
    exit 1
fi

# === MOVE TO PACMAN CACHE ===
echo "[RAMBUILD] Moving to /var/cache/pacman/pkg..."
sudo mv "$PACKAGE_FILE" /var/cache/pacman/pkg/

# === AUTO-INSTALL ===
PKG_NAME=$(basename "$PACKAGE_FILE")
echo "[RAMBUILD] Installing $PKG_NAME..."
sudo pacman -U --noconfirm /var/cache/pacman/pkg/"$PKG_NAME"

# === CLEAN UP ===
echo "[RAMBUILD] Cleaning up tmpfs..."
sudo umount "$TMPFS_DIR"

echo "[RAMBUILD] Done! Log saved to $LOG"
exit 0

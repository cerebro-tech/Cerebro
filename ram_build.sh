#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

PACKAGE="$1"
shift || true
LOG_FILE="$LOG_DIR/ram_build-${PACKAGE}.log"

echo "[*] Building $PACKAGE in RAM..."
echo "[*] Logging to $LOG_FILE"

# 1. Determine available RAM
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
ZRAM_MB=$(( MEM_MB / 2 ))   # half RAM for zram
BUILD_DIR="/tmp/ram_build_$PACKAGE"

mkdir -p "$BUILD_DIR"

# 2. Adjust swap priority if needed
ZRAM_DEV="/dev/zram0"
if ! grep -q "$ZRAM_DEV" /proc/swaps; then
    echo "[*] Initializing ZRAM..."
    sudo modprobe zram
    echo $ZRAM_MB"M" | sudo tee /sys/block/zram0/disksize
    sudo mkswap $ZRAM_DEV
    sudo swapon -p 100 $ZRAM_DEV
fi

# Check for disk swap
SWAP_ACTIVE=$(swapon --show=NAME | grep -v "$ZRAM_DEV" || true)
if [ -n "$SWAP_ACTIVE" ]; then
    sudo swapoff $SWAP_ACTIVE
    sudo swapon -p 10 $SWAP_ACTIVE
fi

# 3. Build in RAM
echo "[*] Copying sources to RAM build directory..."
cp -r . "$BUILD_DIR" || true
cd "$BUILD_DIR"

# 4. Handle AUR or Pacman builds
if [ "$PACKAGE" == "paru" ]; then
    echo "[*] Building paru..."
    git clone https://aur.archlinux.org/paru.git . &>> "$LOG_FILE"
    makepkg -si --noconfirm &>> "$LOG_FILE"
else
    if command -v paru &>/dev/null; then
        echo "[*] Using paru to build $PACKAGE..."
        paru -S --noconfirm --needed "$PACKAGE" "$@" &>> "$LOG_FILE"
    else
        echo "[*] Using pacman to install $PACKAGE..."
        sudo pacman -S --noconfirm --needed "$PACKAGE" "$@" &>> "$LOG_FILE"
    fi
fi

# 5. Cleanup
cd "$SCRIPT_DIR"
rm -rf "$BUILD_DIR"

echo "[*] Build finished: $PACKAGE"
echo "[*] Check log: $LOG_FILE"

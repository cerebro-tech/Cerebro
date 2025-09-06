#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
# RAM-aware build script for PKGBUILD / CMake / other source builds

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_FILE="$SCRIPT_DIR/ram_build-paru.log"
mkdir -p "$SCRIPT_DIR"

# === Source shell configs ===
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -f ~/.zshrc ]] && source ~/.zshrc

# === Detect total RAM ===
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_MB=$((MEM_KB / 1024))
BUILD_RAM_MB=$((MEM_MB - 1536))   # Use available RAM minus 1.5 GB
[[ $BUILD_RAM_MB -lt 512 ]] && BUILD_RAM_MB=512  # Minimum 512MB

echo "[*] Total RAM: ${MEM_MB} MB, Build RAM: ${BUILD_RAM_MB} MB"

# === Setup ZRAM ===
if ! lsmod | grep -q zram; then
    echo "[*] Loading zram module..."
    sudo modprobe zram
fi
ZRAM_SIZE=$((BUILD_RAM_MB * 1024 * 512 / 1024))  # RAM/2 in MB
echo "[*] Configuring ZRAM: ${ZRAM_SIZE}MB with lz4..."
echo $ZRAM_SIZE | sudo tee /sys/block/zram0/disksize
sudo mkfs.ext4 -q /dev/zram0
sudo mount -o rw,relatime /dev/zram0 /mnt || true

# === Swap check & priority ===
SWAP_ACTIVE=$(swapon --show=NAME --noheadings || true)
if [[ -n "$SWAP_ACTIVE" ]]; then
    echo "[*] Swap detected: $SWAP_ACTIVE"
    sudo swapon --priority 5 $SWAP_ACTIVE
    sudo swapoff /dev/zram0
else
    echo "[*] No swap detected, using only ZRAM"
    sudo swapon /dev/zram0 --priority 100
fi

# === Ensure build tools ===
for tool in mold ninja ccache pigz; do
    if ! command -v $tool &>/dev/null; then
        echo "[*] Installing $tool..."
        sudo pacman -S --noconfirm $tool || true
    fi
done

# === Backup and update makepkg.conf and rust.conf ===
for conf in makepkg.conf rust.conf; do
    CONF_FILE="/etc/$conf"
    [[ -f "$CONF_FILE" ]] && sudo cp "$CONF_FILE" "${CONF_FILE}.bak"
    echo "[*] Updating $conf..."
    curl -fsSL "https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/$conf" \
        | sudo tee "$CONF_FILE" >/dev/null
done

# === Detect build folder ===
SRC_DIR="${1:-$(pwd)}"
if [[ ! -d "$SRC_DIR" ]]; then
    echo "[!] Source directory $SRC_DIR not found"
    exit 1
fi
cd "$SRC_DIR"

# === Detect build type ===
if [[ -f "PKGBUILD" ]]; then
    echo "[*] Building PKGBUILD in RAM..."
    makepkg -s -C --noconfirm --cachedir /dev/shm >>"$LOG_FILE" 2>&1
elif [[ -f "CMakeLists.txt" ]]; then
    echo "[*] CMake build detected"
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release -G Ninja -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    ninja -j$(nproc) | tee -a "$LOG_FILE"
    ninja install | tee -a "$LOG_FILE"
else
    echo "[*] Generic make build detected"
    make -j$(nproc) | tee -a "$LOG_FILE"
    sudo make install | tee -a "$LOG_FILE"
fi

# === Cleanup ===
echo "[*] Cleaning up RAM build directories..."
sync
[[ -d /mnt ]] && sudo umount /mnt || true
[[ -b /dev/zram0 ]] && sudo swapoff /dev/zram0
echo "[*] Build finished. Log saved to $LOG_FILE"

#!/usr/bin/env bash
# Cerebro setup script - full OS optimizations and RAM-aware builds

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR"

# -------------------------
# 1️⃣ Detect and setup swap & ZRAM
# -------------------------
echo "[*] Checking swap and ZRAM..."

TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
ZRAM_SIZE=$((3*1024*1024*1024)) # 3 GB
ZRAM_DEV="/dev/zram0"

# Enable swap if inactive
if ! swapon --show | grep -q '^'; then
    SWAP_PART=$(lsblk -o NAME,TYPE,SIZE,MOUNTPOINT | grep -E 'swap|SWAP' | awk '{print $1}' | head -n1)
    if [[ -n "$SWAP_PART" ]]; then
        echo "[*] Activating swap on /dev/$SWAP_PART..."
        sudo mkswap "/dev/$SWAP_PART"
        sudo swapon "/dev/$SWAP_PART"
    else
        echo "[*] No swap partition found. Will use only ZRAM."
    fi
fi

# Setup ZRAM
if [[ ! -b "$ZRAM_DEV" ]]; then
    echo "[*] Creating ZRAM device..."
    echo lz4 | sudo tee /sys/block/zram0/comp_algorithm
    echo "$ZRAM_SIZE" | sudo tee /sys/block/zram0/disksize
    sudo mkswap "$ZRAM_DEV"
    sudo swapon -p 100 "$ZRAM_DEV"
    echo "[*] ZRAM enabled: $ZRAM_SIZE bytes with lz4"
fi

# Adjust swappiness
sudo sysctl vm.swappiness=10
sudo sysctl vm.vfs_cache_pressure=50

# -------------------------
# 2️⃣ Install base dependencies
# -------------------------
echo "[*] Installing base dependencies..."
sudo pacman -Syu --needed --noconfirm ninja cmake ccache mold wget

# -------------------------
# 3️⃣ Setup RAM build script
# -------------------------
RAM_BUILD="$SCRIPT_DIR/ram_build.sh"
if [[ ! -f "$RAM_BUILD" ]]; then
    echo "[*] Downloading ram_build.sh..."
    curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/ram_build.sh -o "$RAM_BUILD"
    chmod +x "$RAM_BUILD"
fi

# -------------------------
# 4️⃣ Compile paru if missing
# -------------------------
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found, building via RAM build..."
    cd "$SCRIPT_DIR"
    git clone https://aur.archlinux.org/paru.git
    cd paru
    "$RAM_BUILD" .
    echo "[*] Paru installed!"
fi

# -------------------------
# 5️⃣ Shell integration
# -------------------------
# Add cerebro_scripts to PATH
if ! grep -q "cerebro_scripts" ~/.bashrc; then
    echo "export PATH=\"\$HOME/cerebro_scripts:\$PATH\"" >> ~/.bashrc
    source ~/.bashrc
fi

if ! grep -q "cerebro_scripts" ~/.zshrc; then
    echo "export PATH=\"\$HOME/cerebro_scripts:\$PATH\"" >> ~/.zshrc
    source ~/.zshrc
fi

echo "[*] Cerebro setup finished!"

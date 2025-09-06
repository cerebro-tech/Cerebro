#!/usr/bin/env bash
# cerebro.sh - Super setup + RAM build integration

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

# --- 1️⃣ Detect RAM and configure ZRAM & swap ---
echo "[*] Configuring RAM stack (RAM + ZRAM + swap)..."
MEM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
AVAILABLE_RAM_MB=$((MEM_MB - 1536)) # RAM - 1.5 GB for system
ZRAM_MB=$((AVAILABLE_RAM_MB / 2))
SWAP_PART=$(findmnt -n -o SOURCE -T /swapfile || echo "")

# Setup ZRAM
if ! swapon --show | grep -q zram0; then
    echo "[*] Initializing ZRAM: $ZRAM_MB MiB"
    sudo modprobe zram
    echo $ZRAM_MB | sudo tee /sys/block/zram0/disksize
    sudo mkswap /dev/zram0
    sudo swapon /dev/zram0
fi

# Activate swap partition if exists
if [ -n "$SWAP_PART" ] && ! swapon --show | grep -q "$SWAP_PART"; then
    echo "[*] Activating swap partition: $SWAP_PART"
    sudo swapon "$SWAP_PART"
fi

# --- 2️⃣ Backup configs ---
echo "[*] Backing up makepkg.conf and rust.conf..."
[ -f /etc/makepkg.conf ] && sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak
[ -f /etc/rust.conf ] && sudo cp /etc/rust.conf /etc/rust.conf.bak

# Download optimized configs
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /etc/makepkg.conf
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o /etc/rust.conf

# --- 3️⃣ Install essential build tools ---
echo "[*] Installing build tools: base-devel, ninja, mold, pigz..."
sudo pacman -Syu --noconfirm base-devel ninja mold pigz

# --- 4️⃣ Download RAM build scripts ---
echo "[*] Downloading RAM build scripts from GitHub..."
mkdir -p "$SCRIPT_DIR/cerebro_scripts"
cd "$SCRIPT_DIR/cerebro_scripts"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/ram_build.sh -o ram_build.sh
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rpacman -o rpacman
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rparu -o rparu
chmod +x ram_build.sh rpacman rparu

# --- 5️⃣ Compile paru if missing ---
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found, building in RAM..."
    ./ram_build.sh paru
fi

# --- 6️⃣ Shell integration ---
echo "[*] Sourcing zshrc if exists..."
[ -f ~/.zshrc ] && source ~/.zshrc
[ -f ~/.bashrc ] && source ~/.bashrc

echo "[*] Cerebro setup complete. You can now use:"
echo "  ~/cerebro_scripts/ram_build.sh <package|git|tarball>"
echo "  ~/cerebro_scripts/rpacman <args>  # builds pacman packages in RAM"
echo "  ~/cerebro_scripts/rparu <args>    # builds AUR packages in RAM"

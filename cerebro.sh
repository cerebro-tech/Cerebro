#!/usr/bin/env bash
# ~/cerebro_scripts/cerebro.sh
set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

echo "[*] Starting Cerebro setup..."

# 1. Setup ZRAM and Swap
echo "[*] Configuring ZRAM and swap..."
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
ZRAM_SIZE_MB=$(( MEM_MB / 2 ))  # Use half RAM for zram
ZRAM_DEV="/dev/zram0"

if ! grep -q "$ZRAM_DEV" /proc/swaps; then
    echo "[*] Initializing ZRAM..."
    sudo modprobe zram
    echo $ZRAM_SIZE_MB"M" | sudo tee /sys/block/zram0/disksize
    sudo mkswap $ZRAM_DEV
    sudo swapon -p 100 $ZRAM_DEV
fi

# Check for any active swap partition
SWAP_ACTIVE=$(swapon --show=NAME | grep -v "$ZRAM_DEV" || true)
if [ -n "$SWAP_ACTIVE" ]; then
    echo "[*] Lowering priority of disk swap..."
    sudo swapoff $SWAP_ACTIVE
    sudo swapon -p 10 $SWAP_ACTIVE
fi

# 2. Install required build tools
echo "[*] Installing Ninja, Mold, Pigz..."
sudo pacman -S --needed --noconfirm ninja mold pigz

# 3. Backup and update makepkg.conf and rust.conf
echo "[*] Backing up makepkg.conf and rust.conf..."
sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak || true
sudo cp /etc/rust.conf /etc/rust.conf.bak || true

echo "[*] Downloading latest configs..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /tmp/makepkg.conf
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o /tmp/rust.conf

sudo mv /tmp/makepkg.conf /etc/makepkg.conf
sudo mv /tmp/rust.conf /etc/rust.conf

# 4. Shell integration
echo "[*] Updating shell configurations..."
grep -qxF "source ~/.bashrc" ~/.bashrc || echo "source ~/.bashrc" >> ~/.bashrc
grep -qxF "source ~/.zshrc" ~/.zshrc || echo "source ~/.zshrc" >> ~/.zshrc
source ~/.bashrc
source ~/.zshrc

# 5. Compile paru via ram_build.sh if missing
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found, compiling via ram_build.sh..."
    if [ ! -f "$SCRIPT_DIR/ram_build.sh" ]; then
        echo "[!] ram_build.sh not found in $SCRIPT_DIR"
        exit 1
    fi
    "$SCRIPT_DIR/ram_build.sh" paru
fi

echo "[*] Cerebro setup completed."

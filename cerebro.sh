#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR/logs"

echo "[*] Setting up ZRAM and swap..."
TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in KB
TOTAL_RAM_MB=$((TOTAL_RAM / 1024))
ZRAM_SIZE_MB=$((TOTAL_RAM_MB / 2))
echo "[*] ZRAM size: ${ZRAM_SIZE_MB} MB"

# Setup ZRAM
sudo modprobe zram
echo $ZRAM_SIZE_MB | sudo tee /sys/block/zram0/disksize
sudo mkswap /dev/zram0
sudo swapon /dev/zram0 -p 100

# Check for active swap
SWAP_ACTIVE=$(swapon --show=NAME --noheadings || true)
if [[ -n "$SWAP_ACTIVE" ]]; then
    echo "[*] Swap active: $SWAP_ACTIVE"
else
    echo "[*] No swap found, skipping physical swap usage"
fi

# Backup makepkg.conf and rust.conf
echo "[*] Backing up configs..."
[ -f /etc/makepkg.conf ] && sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak
[ -f /etc/rust.conf ] && sudo cp /etc/rust.conf /etc/rust.conf.bak

# Download Cerebro configs
echo "[*] Downloading optimized configs..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o "$HOME/.makepkg.conf"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o "$HOME/.rust.conf"

# Install essential tools
echo "[*] Installing essential build tools..."
sudo pacman -Sy --noconfirm ninja mold pigz base-devel

# Compile paru if missing
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found, compiling via ram_build.sh..."
    "$SCRIPT_DIR/ram_build.sh" paru
fi

# Setup rpacman and rparu
echo "[*] Setting up rpacman and rparu..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rpacman -o "$SCRIPT_DIR/rpacman"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rparu -o "$SCRIPT_DIR/rparu"
chmod +x "$SCRIPT_DIR/rpacman" "$SCRIPT_DIR/rparu"

# Add shell integration
echo "[*] Adding shell integration..."
grep -qxF "source $SCRIPT_DIR/rpacman" ~/.bashrc || echo "source $SCRIPT_DIR/rpacman" >> ~/.bashrc
grep -qxF "source $SCRIPT_DIR/rparu" ~/.bashrc || echo "source $SCRIPT_DIR/rparu" >> ~/.bashrc
grep -qxF "source ~/.zshrc" ~/.bashrc || echo "source ~/.zshrc" >> ~/.bashrc

grep -qxF "source $SCRIPT_DIR/rpacman" ~/.zshrc || echo "source $SCRIPT_DIR/rpacman" >> ~/.zshrc
grep -qxF "source $SCRIPT_DIR/rparu" ~/.zshrc || echo "source $SCRIPT_DIR/rparu" >> ~/.zshrc

echo "[*] Cerebro setup completed. Please restart your shell."

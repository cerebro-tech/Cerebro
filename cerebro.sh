#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

echo "[*] Starting Cerebro setup..."

### ------------------------
### 1. ZRAM + Swap Setup
### ------------------------
MEM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
ZRAM_SIZE_MB=$(( MEM_MB / 2 ))  # zram = half RAM
ZRAM_DEV="/dev/zram0"

# Load zram module
if ! lsmod | grep -q zram; then
    echo "[*] Loading zram module..."
    modprobe zram
fi

# Configure zram
echo $ZRAM_SIZE_MB"M" > /sys/block/zram0/disksize
echo lz4 > /sys/block/zram0/comp_algorithm
mkswap $ZRAM_DEV
swapon $ZRAM_DEV -p 100

# Check if real swap partition exists
SWAP_PART=$(swapon --show=NAME --noheadings | grep -v "$ZRAM_DEV" || true)
if [[ -n "$SWAP_PART" ]]; then
    echo "[*] Found real swap: $SWAP_PART, adjusting priorities..."
    swapoff $SWAP_PART || true
    swapon $SWAP_PART -p 50
fi

### ------------------------
### 2. Download helper scripts
### ------------------------
for script in ram_build.sh rpacman rparu; do
    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
        echo "[*] Downloading $script..."
        curl -fsSL "https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/$script" -o "$SCRIPT_DIR/$script"
        chmod +x "$SCRIPT_DIR/$script"
    fi
done

### ------------------------
### 3. Backup config files
### ------------------------
for conf in makepkg.conf rust.conf; do
    if [[ -f "/etc/$conf" ]]; then
        echo "[*] Backing up $conf..."
        cp -n "/etc/$conf" "/etc/$conf.bak"
    fi
done

### ------------------------
### 4. Build paru if missing
### ------------------------
if ! command -v paru &>/dev/null; then
    echo "[*] paru not found, building via ram_build..."
    "$SCRIPT_DIR/ram_build.sh" "https://aur.archlinux.org/paru.git"
fi

### ------------------------
### 5. Install performance tools
### ------------------------
for tool in ninja mold pigz; do
    if ! command -v $tool &>/dev/null; then
        echo "[*] Installing $tool via rpacman..."
        "$SCRIPT_DIR/rpacman" -S --noconfirm $tool
    fi
done

### ------------------------
### 6. Shell integration
### ------------------------
if [[ -f "$HOME/.zshrc" ]]; then
    echo "[*] Sourcing ~/.zshrc..."
    source "$HOME/.zshrc"
fi

echo "[*] Cerebro setup completed successfully!"

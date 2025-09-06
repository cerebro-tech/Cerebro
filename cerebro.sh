#!/usr/bin/env bash
# cerebro.sh - Download and setup RAM build environment

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

echo "[*] Starting Cerebro environment setup..."

# 1. Setup ZRAM + SWAP
echo "[*] Configuring ZRAM and SWAP..."
MEM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
ZRAM_SIZE_MB=$(( MEM_MB / 2 ))   # Half of total RAM for ZRAM
SWAP_ACTIVE=$(swapon --show | wc -l)
if (( SWAP_ACTIVE > 0 )); then
    echo "[*] Swap detected, prioritizing ZRAM over swap..."
    swapon -s
else
    echo "[*] No swap detected, using only ZRAM..."
fi

modprobe zram num_devices=1
echo $((ZRAM_SIZE_MB * 1024 * 1024)) > /sys/block/zram0/disksize
mkfs.ext4 /dev/zram0
mount -o defaults /dev/zram0 /mnt/tmp || true

# 2. Backup makepkg.conf and rust.conf
echo "[*] Backing up configs..."
for f in /etc/makepkg.conf /etc/rustc/rust.conf; do
    if [[ -f $f ]]; then
        cp "$f" "$f.bak_$(date +%s)"
        echo "[*] Backup created: $f.bak_$(date +%s)"
    fi
done

# 3. Download necessary scripts/tools from GitHub
echo "[*] Downloading RAM build scripts and tools..."
mkdir -p "$SCRIPT_DIR"/tools

TOOLS=(
    "ram_build.sh"
    "rparu"
    "rpacman"
)

for tool in "${TOOLS[@]}"; do
    curl -fsSL "https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/$tool" -o "$SCRIPT_DIR/tools/$tool"
    chmod +x "$SCRIPT_DIR/tools/$tool"
done

# 4. Install required build utilities
echo "[*] Installing build utilities (mold, ninja, pigz)..."
for pkg in mold ninja pigz; do
    if ! command -v "$pkg" &>/dev/null; then
        echo "[*] Installing $pkg..."
        paru -S --noconfirm "$pkg"
    fi
done

# 5. Compile paru if missing
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found, compiling with RAM build..."
    "$SCRIPT_DIR/tools/ram_build.sh" https://aur.archlinux.org/paru.git
fi

# 6. Shell integration
echo "[*] Sourcing shell configurations..."
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -f ~/.zshrc ]] && source ~/.zshrc

echo "[*] Cerebro environment setup completed!"

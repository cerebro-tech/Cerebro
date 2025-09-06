#!/usr/bin/env bash
# ~/cerebro_scripts/cerebro.sh
# Cerebro setup: ZRAM, swap, build tools, configs, paru, optimizations

set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

echo "[*] Starting Cerebro setup..."

# 1️⃣ Detect available RAM
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
echo "[*] Detected RAM: ${MEM_MB}MB"

# 2️⃣ Setup ZRAM
echo "[*] Setting up ZRAM..."
ZRAM_SIZE_MB=$(( MEM_MB / 2 ))
modprobe zram
echo $ZRAM_SIZE_MB > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
echo "[*] ZRAM size: ${ZRAM_SIZE_MB}MB with priority 100"

# 3️⃣ Detect existing swap partitions
if swapon --show | grep -q '^'; then
    echo "[*] Swap detected, lowering priority to 50..."
    for sw in $(swapon --show=NAME --noheadings); do
        swapoff "$sw"
        swapon -p 50 "$sw"
    done
else
    echo "[*] No swap partition found, only ZRAM will be used."
fi

# 4️⃣ Update system & install base packages
echo "[*] Installing base packages..."
sudo pacman -Sy --noconfirm \
  base base-devel linux-zen linux-firmware intel-ucode \
  networkmanager sudo zsh xfsprogs e2fsprogs efivar \
  git curl wget unzip tar

# 5️⃣ Install build tools: mold, ninja, pigz
echo "[*] Installing build tools..."
sudo pacman -Sy --noconfirm ninja pigz
sudo pacman -Sy --noconfirm --needed mold || true

# 6️⃣ Backup and replace makepkg.conf and rust.conf
echo "[*] Backing up makepkg.conf and rust.conf..."
[ -f /etc/makepkg.conf ] && sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /etc/makepkg.conf

[ -f /etc/rust.conf ] && sudo cp /etc/rust.conf /etc/rust.conf.bak
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o /etc/rust.conf

# 7️⃣ Source shell configs
echo "[*] Sourcing shell configs..."
source ~/.bashrc || true
[ -f ~/.zshrc ] && source ~/.zshrc

# 8️⃣ Compile paru if missing
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found, compiling via ram_build.sh..."
    "$SCRIPT_DIR/ram_build.sh" git+https://aur.archlinux.org/paru.git
fi

# 9️⃣ Download rparu and rpacman helpers
echo "[*] Downloading rparu and rpacman..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rparu -o "$SCRIPT_DIR/rparu"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rpacman -o "$SCRIPT_DIR/rpacman"
chmod +x "$SCRIPT_DIR/rparu" "$SCRIPT_DIR/rpacman"

# 1️⃣0️⃣ Final message
echo "[*] Cerebro setup complete! You can now use:"
echo "    $SCRIPT_DIR/rparu <package>  # Build AUR packages in RAM"
echo "    $SCRIPT_DIR/rpacman <package> # Build/install packages in RAM"

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR"

echo "[*] Detecting system RAM..."
MEM_BYTES=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
RESERVE_BYTES=$(( 1_500 * 1024 * 1024 ))
if (( MEM_BYTES <= RESERVE_BYTES )); then
    BUILD_RAM=$(( MEM_BYTES / 2 ))
else
    BUILD_RAM=$(( MEM_BYTES - RESERVE_BYTES ))
fi

echo "[*] Total RAM: $((MEM_BYTES/1024/1024)) MB, reserved: 1.5 GB, usable for builds: $((BUILD_RAM/1024/1024)) MB"

# ------------------------
# 1️⃣ ZRAM & Swap Setup
# ------------------------
echo "[*] Setting up ZRAM..."
ZRAM_SIZE=$(( BUILD_RAM / 2 ))
if (( ZRAM_SIZE > 0 )); then
    if ! systemctl is-active --quiet systemd-zram-setup@zram0; then
        echo "ZRAM size: $((ZRAM_SIZE/1024/1024)) MB"
        sudo systemctl enable --now systemd-zram-setup@zram0 || true
    fi
else
    echo "[*] Skipping ZRAM setup (RAM too low or already active)"
fi

SWAP_ACTIVE=$(swapon --show=NAME | wc -l)
if (( SWAP_ACTIVE > 0 )); then
    echo "[*] Swap detected, ensuring priority..."
    sudo swapon --show
else
    echo "[*] No swap detected, skipping swap adjustments"
fi

# ------------------------
# 2️⃣ Install essential packages
# ------------------------
echo "[*] Installing essential packages: mold, ninja, ccache, pigz"
sudo pacman -S --needed --noconfirm mold ninja ccache pigz curl git base-devel

# ------------------------
# 3️⃣ Backup and update configs
# ------------------------
echo "[*] Backing up makepkg.conf and rust.conf..."
sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak || true
sudo cp /etc/rustc/rust.conf /etc/rustc/rust.conf.bak || true

echo "[*] Downloading optimized configs..."
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /etc/makepkg.conf
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o /etc/rustc/rust.conf

# ------------------------
# 4️⃣ Shell integration
# ------------------------
echo "[*] Detecting shell..."
if [[ "$SHELL" =~ "zsh" ]]; then
    SHELLRC="$HOME/.zshrc"
else
    SHELLRC="$HOME/.bashrc"
fi

echo "[*] Adding source command to $SHELLRC..."
grep -qxF "source $SCRIPT_DIR/*.sh" "$SHELLRC" || echo "source $SCRIPT_DIR/*.sh" >> "$SHELLRC"
source "$SHELLRC"

# ------------------------
# 5️⃣ Download remaining Cerebro scripts
# ------------------------
echo "[*] Downloading scripts to $SCRIPT_DIR..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/ram_build.sh -o "$SCRIPT_DIR/ram_build.sh"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rpacman -o "$SCRIPT_DIR/rpacman"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rparu -o "$SCRIPT_DIR/rparu"

chmod +x "$SCRIPT_DIR/"*.sh "$SCRIPT_DIR"/rparu "$SCRIPT_DIR"/rpacman

# ------------------------
# 6️⃣ Auto-detect tmpfs for builds
# ------------------------
echo "[*] Setting up tmpfs for RAM builds..."
mkdir -p /tmp/ram_build
sudo mount -t tmpfs -o size=${BUILD_RAM} tmpfs /tmp/ram_build || true
echo "[*] tmpfs mounted at /tmp/ram_build, size: $((BUILD_RAM/1024/1024)) MB"

# ------------------------
# 7️⃣ Compile paru if missing
# ------------------------
if ! command -v paru &>/dev/null; then
    echo "[*] paru not found, compiling via ram_build.sh..."
    "$SCRIPT_DIR/ram_build.sh" https://aur.archlinux.org/paru.git
fi

echo "[*] Cerebro setup completed successfully!"

#!/usr/bin/env bash
set -euo pipefail

echo "[*] Cerebro setup starting..."

# -------------------------------
# 0. Ensure ~/cerebro_scripts exists
# -------------------------------
mkdir -p ~/cerebro_scripts
cd ~/cerebro_scripts

# 1. Setup ZRAM + SWAP
echo "[*] Configuring ZRAM and SWAP..."
sudo pacman -Syu --needed --noconfirm zram-generator

# 1.2 Configure ZRAM (half of RAM, lz4)
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$(( TOTAL_MEM / 1024 ))
ZRAM_SIZE=$(( TOTAL_MEM_MB / 2 ))

sudo tee /etc/systemd/zram-generator.conf >/dev/null <<EOF
[zram0]
zram-size = ${ZRAM_SIZE}M
compression-algorithm = lz4
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now systemd-zram-setup@zram0.service

# 1.3 Check swap partition
if swapon --show | grep -q partition; then
  echo "[*] Swap partition detected, adjusting priorities..."
  SWAP_PART=$(swapon --show | awk '/partition/ {print $1}')
  sudo swapoff "$SWAP_PART"
  sudo swapon --priority 50 "$SWAP_PART"
  sudo swapoff /dev/zram0
  sudo swapon --priority 100 /dev/zram0
else
  echo "[*] No swap partition detected, using only ZRAM."
  sudo swapoff /dev/zram0
  sudo swapon --priority 100 /dev/zram0
fi

# 2. Ensure dependencies
echo "[*] Installing required packages..."
sudo pacman -S --needed --noconfirm mold ninja ccache pigz

# 2.1 Backup and replace configs
sudo cp -n /etc/makepkg.conf /etc/makepkg.conf.bak
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /etc/makepkg.conf

sudo cp -n /etc/rust.conf /etc/rust.conf.bak
sudo curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o /etc/rust.conf

# 3. Download Cerebro scripts
echo "[*] Downloading Cerebro scripts..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/ram_build.sh -o ram_build.sh
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rpacman -o rpacman
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rparu -o rparu
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/cerebro.sh -o cerebro.sh

chmod +x ram_build.sh rpacman rparu cerebro.sh

# 4. Shell integration (zshrc, bashrc)
echo "[*] Updating shell rc..."
if [ -n "${ZSH_VERSION:-}" ]; then
  SHELL_RC="$HOME/.zshrc"
  SOURCE_CMD="source ~/.zshrc"
else
  SHELL_RC="$HOME/.bashrc"
  SOURCE_CMD="source ~/.bashrc"
fi

if ! grep -q "cerebro_scripts" "$SHELL_RC"; then
  {
    echo 'export PATH="$HOME/cerebro_scripts:$PATH"'
    echo "$SOURCE_CMD || true"
  } >> "$SHELL_RC"
fi

# 5. Ensure paru installed (build with ram_build.sh if missing)
if ! command -v paru &>/dev/null; then
  echo "[*] Paru not found, compiling..."
  git clone https://aur.archlinux.org/paru.git /tmp/paru
  cd /tmp/paru
  ~/cerebro_scripts/ram_build.sh makepkg -si --noconfirm
  cd -
fi

echo "[✔] Cerebro setup completed."

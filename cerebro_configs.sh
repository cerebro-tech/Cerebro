#!/usr/bin/env bash
# cerebro_conf.sh - configs for performance
# Date: $(date +%Y-%m-%d)

set -euo pipefail

# Required packages
PKGS=(mold ninja ccache pigz pbzip2)

echo "[*] Checking and installing required packages..."
for pkg in "${PKGS[@]}"; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
        echo "    -> Installing $pkg..."
        sudo pacman -Syu --needed --noconfirm "$pkg"
    else
        echo "    -> $pkg already installed."
    fi
done

# Backup function
backup_config() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
        echo "[*] Backing up $file to $backup"
        sudo cp -f "$file" "$backup"
    fi
}

# Apply optimized configs
echo "[*] Applying optimized configs..."

# pacman.conf
backup_config /etc/pacman.conf
sudo curl -fsSL \
  https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/pacman.conf \
  -o /etc/pacman.conf

# makepkg.conf
backup_config /etc/makepkg.conf
sudo curl -fsSL \
  https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf \
  -o /etc/makepkg.conf

# rust.conf
backup_config /etc/rust.conf
sudo curl -fsSL \
  https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf \
  -o /etc/rust.conf

echo "[✓] Optimization applied successfully!"
echo "    Backups are stored as *.bak.<timestamp> in /etc"

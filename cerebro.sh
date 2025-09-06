#!/usr/bin/env bash
# ~/cerebro_scripts/cerebro.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"

echo "[*] Backing up configs..."
[[ -f /etc/makepkg.conf ]] && sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak
[[ -f /etc/rust.conf ]] && sudo cp /etc/rust.conf /etc/rust.conf.bak

echo "[*] Downloading latest configs..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o /etc/makepkg.conf
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o /etc/rust.conf

echo "[*] Installing essential build tools..."
sudo pacman -S --noconfirm ninja mold pigz base-devel git

echo "[*] Setting up ZRAM + swap (run only once)..."
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
ZRAM_MB=$(( TOTAL_RAM_MB / 2 ))
sudo modprobe zram num_devices=1
echo "${ZRAM_MB}M" | sudo tee /sys/block/zram0/disksize
sudo mkswap /dev/zram0
sudo swapon --priority 200 /dev/zram0

# Enable existing swap partitions with lower priority
for s in $(swapon --show=NAME --noheadings); do
    [[ "$s" != "/dev/zram0" ]] && sudo swapon --priority 100 "$s"
done

echo "[*] Compiling Paru if missing..."
if ! command -v paru &>/dev/null; then
    TMPDIR="$SCRIPT_DIR/tmp_paru"
    mkdir -p "$TMPDIR"
    git clone https://aur.archlinux.org/paru.git "$TMPDIR"
    "$SCRIPT_DIR/ram_build.sh" "$TMPDIR" "ram_build-paru.log"
    rm -rf "$TMPDIR"
fi

echo "[*] Cerebro environment setup completed!"

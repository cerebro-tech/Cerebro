#!/usr/bin/env bash
set -euo pipefail

echo "[*] Starting Cerebro setup..."

# --- 1. Disable existing ZRAM ---
echo "[*] Checking existing ZRAM devices..."
if ls /dev/zram* &>/dev/null; then
    echo "[*] Disabling existing ZRAM..."
    for z in /dev/zram*; do
        sudo swapoff "$z" 2>/dev/null || true
    done
    for z in /sys/block/zram*; do
        echo 1 | sudo tee "$z/reset" >/dev/null
    done
    sudo modprobe -r zram 2>/dev/null || true
    echo "[*] Existing ZRAM disabled."
else
    echo "[*] No existing ZRAM found."
fi

# --- 2. Check swap ---
SWAP_ACTIVE=$(swapon --show --noheadings | wc -l)
if [[ $SWAP_ACTIVE -gt 0 ]]; then
    echo "[*] Swap partition detected and active. ZRAM priority will be higher."
    ZRAM_PRIORITY=100
    SWAP_PRIORITY=50
else
    echo "[*] No swap partition detected. Using ZRAM only."
    ZRAM_PRIORITY=100
    SWAP_PRIORITY=0
fi

# --- 3. Setup ZRAM ---
RAM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')  # in KB
RAM_FOR_ZRAM=$(( (RAM_TOTAL / 2) * 1024 ))                    # in bytes
echo "[*] Creating new ZRAM device with $((RAM_FOR_ZRAM / 1024 / 1024)) MB..."

sudo modprobe zram
echo 1 | sudo tee /sys/block/zram0/reset >/dev/null
echo "$RAM_FOR_ZRAM" | sudo tee /sys/block/zram0/disksize >/dev/null
sudo mkswap /dev/zram0
sudo swapon -p $ZRAM_PRIORITY /dev/zram0
echo "[*] ZRAM setup complete."

# --- 4. Download required scripts ---
SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR"

echo "[*] Downloading ram_build.sh, rparu, rpacman..."
for f in ram_build.sh rparu rpacman; do
    curl -fsSL "https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/$f" -o "$SCRIPT_DIR/$f"
    chmod +x "$SCRIPT_DIR/$f"
done

# --- 5. Backup and update configs ---
for cfg in makepkg.conf rust.conf; do
    if [[ -f "/etc/$cfg" ]]; then
        echo "[*] Backing up /etc/$cfg to /etc/${cfg}.bak"
        sudo cp "/etc/$cfg" "/etc/${cfg}.bak"
    fi
    curl -fsSL "https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/$cfg" | sudo tee "/etc/$cfg" >/dev/null
done

# --- 6. Install paru if missing ---
if ! command -v paru &>/dev/null; then
    echo "[*] paru not found, building via ram_build..."
    "$SCRIPT_DIR/ram_build.sh" "https://aur.archlinux.org/paru.git"
fi

# --- 7. Shell integrations ---
if [[ -f "$HOME/.zshrc" ]]; then
    echo "[*] Sourcing ~/.zshrc..."
    source "$HOME/.zshrc"
fi

echo "[*] Cerebro setup finished."

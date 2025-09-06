#!/usr/bin/env bash
# cerebro.sh - Cerebro all-in-one installer

set -euo pipefail

SCRIPT_DIR="$HOME/cerebro_scripts"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR" "$LOG_DIR"

echo "[*] Starting Cerebro setup..."

# ------------------------------
# 1️⃣ ZRAM + Swap setup
# ------------------------------
echo "[*] Setting up ZRAM + Swap..."
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
ZRAM_SIZE_MB=$((TOTAL_RAM_MB / 2))
SWAP_ACTIVE=$(swapon --show | wc -l)

if [ "$SWAP_ACTIVE" -eq 0 ]; then
    echo "[*] No swap active. Skipping swap priority."
    echo "[*] Creating ZRAM device..."
    sudo modprobe zram
    echo "$ZRAM_SIZE_MB"M | sudo tee /sys/block/zram0/disksize
    sudo mkswap /dev/zram0
    sudo swapon -p 100 /dev/zram0
else
    echo "[*] Swap detected. Setting ZRAM priority higher..."
    sudo modprobe zram
    echo "$ZRAM_SIZE_MB"M | sudo tee /sys/block/zram0/disksize
    sudo mkswap /dev/zram0
    sudo swapon -p 200 /dev/zram0
fi

# Use lz4 compression
echo lz4 | sudo tee /sys/block/zram0/comp_algorithm

# ------------------------------
# 2️⃣ Backup & update configs
# ------------------------------
echo "[*] Backing up makepkg.conf and rust.conf..."
sudo cp /etc/makepkg.conf /etc/makepkg.conf.bak
sudo cp /etc/rust.conf /etc/rust.conf.bak || true

echo "[*] Downloading new configs..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/makepkg.conf -o ~/makepkg.conf
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rust.conf -o ~/rust.conf

sudo mv ~/makepkg.conf /etc/makepkg.conf
sudo mv ~/rust.conf /etc/rust.conf

# ------------------------------
# 3️⃣ Install essential tools
# ------------------------------
echo "[*] Installing base tools..."
sudo pacman -Syu --needed --noconfirm base-devel git ninja mold pigz

# ------------------------------
# 4️⃣ Setup RAM build script (ram_build)
# ------------------------------
cat > "$SCRIPT_DIR/ram_build.sh" << 'EOF'
#!/usr/bin/env bash
# RAM build helper for Cerebro
set -euo pipefail

BUILD_DIR=$(mktemp -d -t rambuild-XXXX)
LOG_FILE="$HOME/cerebro_scripts/logs/ram_build.log"
echo "[*] Building in RAM at $BUILD_DIR" | tee -a "$LOG_FILE"

# Copy source to tmpfs
SRC_DIR=$(pwd)
cp -r "$SRC_DIR"/* "$BUILD_DIR/"

cd "$BUILD_DIR"
# Use makepkg or cargo depending on folder
if [ -f "PKGBUILD" ]; then
    makepkg -si | tee -a "$LOG_FILE"
elif [ -f "Cargo.toml" ]; then
    cargo build --release | tee -a "$LOG_FILE"
else
    echo "[!] No PKGBUILD or Cargo.toml found. Skipping build." | tee -a "$LOG_FILE"
fi

cd "$SRC_DIR"
rm -rf "$BUILD_DIR"
EOF

chmod +x "$SCRIPT_DIR/ram_build.sh"

# ------------------------------
# 5️⃣ Compile Paru if missing
# ------------------------------
if ! command -v paru &>/dev/null; then
    echo "[*] Paru not found. Installing via RAM build..."
    mkdir -p ~/aur
    cd ~/aur
    git clone https://aur.archlinux.org/paru.git
    cd paru
    "$SCRIPT_DIR/ram_build.sh"
    cd ~
else
    echo "[*] Paru already installed."
fi

# ------------------------------
# 6️⃣ Setup rpacman & rparu aliases
# ------------------------------
echo "[*] Setting up rpacman & rparu..."
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rpacman -o "$SCRIPT_DIR/rpacman"
curl -fsSL https://raw.githubusercontent.com/cerebro-tech/Cerebro/refs/heads/main/rparu -o "$SCRIPT_DIR/rparu"
chmod +x "$SCRIPT_DIR/rpacman" "$SCRIPT_DIR/rparu"

# ------------------------------
# 7️⃣ Shell integration
# ------------------------------
echo "[*] Adding aliases to ~/.bashrc and ~/.zshrc..."
grep -qxF 'source ~/.bashrc' ~/.bashrc || echo "source ~/.bashrc" >> ~/.bashrc
grep -qxF 'source ~/.zshrc' ~/.zshrc || echo "source ~/.zshrc" >> ~/.zshrc
grep -qxF "alias rpacman=\"$SCRIPT_DIR/rpacman\"" ~/.bashrc || echo "alias rpacman=\"$SCRIPT_DIR/rpacman\"" >> ~/.bashrc
grep -qxF "alias rparu=\"$SCRIPT_DIR/rparu\"" ~/.bashrc || echo "alias rparu=\"$SCRIPT_DIR/rparu\"" >> ~/.bashrc
grep -qxF "alias rpacman=\"$SCRIPT_DIR/rpacman\"" ~/.zshrc || echo "alias rpacman=\"$SCRIPT_DIR/rpacman\"" >> ~/.zshrc
grep -qxF "alias rparu=\"$SCRIPT_DIR/rparu\"" ~/.zshrc || echo "alias rparu=\"$SCRIPT_DIR/rparu\"" >> ~/.zshrc

echo "[*] Cerebro setup finished! Reload your shell:"
echo "source ~/.zshrc  # or source ~/.bashrc"

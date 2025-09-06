#!/usr/bin/env bash
# ~/cerebro_scripts/cerebro.sh
# All-in-one Cerebro setup: RAM builds, wrappers, PATH, auto paru

set -euo pipefail
SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR"

# --- Source shell configs ---
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -f ~/.zshrc ]] && source ~/.zshrc

# --- Install paru if missing ---
if ! command -v paru &>/dev/null; then
    echo "[*] Installing paru..."
    sudo pacman -Syu --needed --noconfirm git base-devel
    cd "$SCRIPT_DIR"
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si --noconfirm
fi

# --- Ensure build tools ---
for tool in mold ninja ccache pigz; do
    sudo pacman -S --needed --noconfirm $tool || true
done

# --- RAM build script ---
RAM_BUILD="$SCRIPT_DIR/ram_build.sh"
cat > "$RAM_BUILD" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# --- Detect RAM ---
TOTAL_RAM=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_RAM_MB=$((TOTAL_RAM / 1024))
AVAILABLE_RAM_MB=$((TOTAL_RAM_MB - 1500))
[[ $AVAILABLE_RAM_MB -lt 512 ]] && AVAILABLE_RAM_MB=512

# --- ZRAM setup ---
ZRAM_SIZE_MB=$(( TOTAL_RAM_MB / 2 ))
sudo modprobe zram num_devices=1
echo $((ZRAM_SIZE_MB * 1024 * 1024)) | sudo tee /sys/block/zram0/disksize
sudo mkswap /dev/zram0
sudo swapon -p 100 /dev/zram0

# --- Enable system swap ---
SWAP_ACTIVE=$(swapon --show=NAME | wc -l)
if [[ $SWAP_ACTIVE -le 0 ]]; then
    echo "[*] No active swap"
else
    sudo swapon -a
fi

# --- Build in RAM ---
SRC_DIR="${1:-$(pwd)}"
BUILD_DIR=$(mktemp -d /dev/shm/ram_build_XXXX)
echo "[*] Building in RAM: $BUILD_DIR"
cd "$SRC_DIR"

# --- Build command ---
if [[ $# -gt 1 ]]; then
    shift
    "$@" | tee -a "$SRC_DIR/ram_build-paru.log"
else
    echo "[*] No command provided"
fi

# --- Cleanup ---
rm -rf "$BUILD_DIR"
sudo swapoff /dev/zram0 || true
sudo rmmod zram || true
EOF
chmod +x "$RAM_BUILD"

# --- rparu wrapper ---
RPARU="$SCRIPT_DIR/rparu"
cat > "$RPARU" <<EOF
#!/usr/bin/env bash
"$RAM_BUILD" "\$(pwd)" paru "\$@"
EOF
chmod +x "$RPARU"

# --- rpacman wrapper ---
RPACMAN="$SCRIPT_DIR/rpacman"
cat > "$RPACMAN" <<EOF
#!/usr/bin/env bash
"$RAM_BUILD" "\$(pwd)" sudo pacman "\$@"
EOF
chmod +x "$RPACMAN"

# --- Add cerebro_scripts to PATH ---
if ! echo "$PATH" | grep -q "$SCRIPT_DIR"; then
    echo "export PATH=\$PATH:$SCRIPT_DIR" >> ~/.bashrc
    echo "export PATH=\$PATH:$SCRIPT_DIR" >> ~/.zshrc
    source ~/.bashrc || true
    source ~/.zshrc || true
fi

echo "[*] Cerebro environment ready!"
echo "Use rparu <pkg> or rpacman <args> to build packages in RAM."

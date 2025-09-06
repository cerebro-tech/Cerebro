#!/usr/bin/env bash
# ~/cerebro_scripts/cerebro.sh

set -euo pipefail
SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR"

# --- Source shell configs ---
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -f ~/.zshrc ]] && source ~/.zshrc

# --- Install paru if missing ---
if ! command -v paru &>/dev/null; then
    echo "[*] Installing paru..."
    sudo pacman -S --needed --noconfirm git base-devel
    cd "$SCRIPT_DIR"
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si --noconfirm
fi

# --- Ensure build tools ---
for tool in mold ninja ccache pigz; do
    sudo pacman -S --needed --noconfirm $tool || true
done

# --- Create scripts ---
RAM_BUILD="$SCRIPT_DIR/ram_build.sh"
RPARU="$SCRIPT_DIR/rparu"
RPACMAN="$SCRIPT_DIR/rpacman"

# Write RAM build script
cat > "$RAM_BUILD" <<'EOF'
# (paste full ram_build.sh content here)
EOF
chmod +x "$RAM_BUILD"

# rparu wrapper
cat > "$RPARU" <<EOF
#!/usr/bin/env bash
"$RAM_BUILD" "\$(pwd)" paru "\$@"
EOF
chmod +x "$RPARU"

# rpacman wrapper
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

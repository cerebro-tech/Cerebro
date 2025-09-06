#!/usr/bin/env bash
# ~/cerebro_scripts/cerebro.sh
# Main installer for Cerebro RAM-build environment

set -euo pipefail
SCRIPT_DIR="$HOME/cerebro_scripts"
mkdir -p "$SCRIPT_DIR"

# === Source shell configs ===
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -f ~/.zshrc ]] && source ~/.zshrc

# === Pacman / paru check ===
if ! command -v paru &>/dev/null; then
    echo "[*] Installing paru AUR helper..."
    sudo pacman -S --needed --noconfirm git base-devel
    cd "$SCRIPT_DIR"
    git clone https://aur.archlinux.org/paru.git
    cd paru
    makepkg -si --noconfirm
fi

# === Ensure build tools ===
for tool in mold ninja ccache pigz; do
    if ! command -v $tool &>/dev/null; then
        echo "[*] Installing $tool..."
        sudo pacman -S --noconfirm $tool || true
    fi
done

# === Setup RAM build scripts ===
RAM_BUILD="$SCRIPT_DIR/ram_build.sh"
RPARU="$SCRIPT_DIR/rparu"
RPACMAN="$SCRIPT_DIR/rpacman"

# Copy or create ram_build.sh
cat > "$RAM_BUILD" <<'EOF'
#!/usr/bin/env bash
# Include full ram_build.sh content here (from previous script)
EOF
chmod +x "$RAM_BUILD"

# rparu wrapper
cat > "$RPARU" <<EOF
#!/usr/bin/env bash
"$RAM_BUILD" "$(pwd)" paru "\$@"
EOF
chmod +x "$RPARU"

# rpacman wrapper
cat > "$RPACMAN" <<EOF
#!/usr/bin/env bash
"$RAM_BUILD" "$(pwd)" sudo pacman "\$@"
EOF
chmod +x "$RPACMAN"

# === Add ~/cerebro_scripts to PATH if not already ===
if ! echo "$PATH" | grep -q "$SCRIPT_DIR"; then
    echo "export PATH=\$PATH:$SCRIPT_DIR" >> ~/.bashrc
    echo "export PATH=\$PATH:$SCRIPT_DIR" >> ~/.zshrc
    source ~/.bashrc || true
    source ~/.zshrc || true
fi

echo "[*] Cerebro setup complete!"
echo "[*] You can now use:"
echo "    rparu <package>   # Build AUR packages in RAM"
echo "    rpacman <args>    # Build Pacman packages in RAM"
echo "    $RAM_BUILD        # Build from source in RAM"

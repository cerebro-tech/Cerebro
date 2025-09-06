#!/usr/bin/env bash
# cerebro.sh - download Cerebro scripts and configs

set -e
GITHUB_RAW="https://raw.githubusercontent.com/cerebro-tech/Cerebro/main"
DEST="$HOME/cerebro_scripts"

echo "[*] Creating scripts folder at $DEST"
mkdir -p "$DEST"

SCRIPTS=("ram_build.sh" "rpacman" "rparu" "rust.conf" "makepkg.conf")

for f in "${SCRIPTS[@]}"; do
    echo "[*] Downloading $f"
    curl -sSL "$GITHUB_RAW/$f" -o "$DEST/$f"
    chmod +x "$DEST/$f" || true
done

# Update .bashrc
if ! grep -q "cerebro_scripts" "$HOME/.bashrc"; then
    echo "[*] Adding Cerebro scripts to PATH in ~/.bashrc"
    echo 'export PATH="$HOME/cerebro_scripts:$PATH"' >> "$HOME/.bashrc"
    echo "[*] Run 'source ~/.bashrc' or restart terminal to apply PATH"
fi

echo "[*] Cerebro scripts installed successfully."

#!/usr/bin/env bash
# cerebro_sudoers.sh — configure sudoers for cbro_build automation

set -euo pipefail

USER_NAME=$(id -un)   # auto-detect current username
SUDOERS_FILE="/etc/sudoers.d/99-cbro_build"

RULES="$USER_NAME ALL=(ALL) NOPASSWD: \
/usr/bin/modprobe zram, \
/usr/bin/mount, /usr/bin/umount, \
/usr/bin/mkswap, /usr/bin/swapon, /usr/bin/swapoff"

echo "[*] Setting up sudoers rule for user: $USER_NAME"
echo "$RULES" | sudo tee "$SUDOERS_FILE" > /dev/null

# Secure permissions
sudo chmod 440 "$SUDOERS_FILE"

echo "[+] Sudoers configured successfully!"
echo "    User '$USER_NAME' can now run cbro_build without entering a password."

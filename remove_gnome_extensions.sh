#!/usr/bin/env bash
# Script: remove_gnome_extensions.sh
# Purpose: Remove default GNOME extensions on Arch Linux

set -euo pipefail

EXT_DIR="/usr/share/gnome-shell/extensions"

echo "[*] Checking for GNOME extensions directory..."
if [[ ! -d "$EXT_DIR" ]]; then
    echo "[-] No extensions found at $EXT_DIR"
    exit 1
fi

echo "[*] The following default extensions will be removed:"
ls "$EXT_DIR"

read -rp "Are you sure you want to remove ALL these extensions? (y/N): " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    echo "[*] Removing default extensions..."
    sudo rm -rf "${EXT_DIR:?}"/*
    echo "[+] Default GNOME extensions removed."
else
    echo "[-] Aborted. No changes made."
    exit 0
fi

echo "[*] Done. Restart GNOME Shell (Alt+F2 → r) or reboot to apply changes."

#!/bin/bash
# Safely disable GNOME printing plugins by renaming their binaries.
# Run with no arguments to disable.
# Run with --restore to restore original binaries.

BIN_DIR="/usr/lib"
PLUGIN_NAMES=("gsd-printer" "gsd-print-notifications")

function disable_plugins() {
  echo "[*] Disabling GNOME print plugins..."
  for plugin in "${PLUGIN_NAMES[@]}"; do
    local orig_path="$BIN_DIR/$plugin"
    local disabled_path="$orig_path.disabled"

    if [ -f "$orig_path" ]; then
      if [ ! -f "$disabled_path" ]; then
        echo "  Renaming $orig_path -> $disabled_path"
        sudo mv "$orig_path" "$disabled_path"
      else
        echo "  $disabled_path already exists, skipping"
      fi
    else
      echo "  $orig_path not found, skipping"
    fi
  done
  echo "[*] Disabled. Please reboot or re-login."
}

function restore_plugins() {
  echo "[*] Restoring GNOME print plugins..."
  for plugin in "${PLUGIN_NAMES[@]}"; do
    local orig_path="$BIN_DIR/$plugin"
    local disabled_path="$orig_path.disabled"

    if [ -f "$disabled_path" ]; then
      if [ ! -f "$orig_path" ]; then
        echo "  Restoring $disabled_path -> $orig_path"
        sudo mv "$disabled_path" "$orig_path"
      else
        echo "  $orig_path already exists, skipping"
      fi
    else
      echo "  $disabled_path not found, skipping"
    fi
  done
  echo "[*] Restored. Please reboot or re-login."
}

case "$1" in
  --restore)
    restore_plugins
    ;;
  *)
    disable_plugins
    ;;
esac

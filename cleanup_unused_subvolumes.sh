#!/usr/bin/env bash
# cleanup_unused_subvolumes.sh

echo "[INFO] Starting cleanup of unused system subvolumes..."

for subvol in "/var/lib/portables" "/var/lib/machines"; do
    if sudo btrfs subvolume show "$subvol" &>/dev/null; then
        echo "[INFO] Deleting unused subvolume: $subvol"
        sudo btrfs subvolume delete "$subvol"
    else
        echo "[INFO] Subvolume not found (already deleted): $subvol"
    fi
done

echo "[INFO] Cleanup completed."

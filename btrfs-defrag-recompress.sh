#!/usr/bin/env bash

# This script defragments and recompresses Btrfs subvolumes, skipping problematic dirs.

TARGET="/"

# Directories to exclude (space-separated)
EXCLUDES=("/home/$USER/.gnupg" "/home/$USER/.pki")

echo "Defragmenting and recompressing: $TARGET"
for EXCLUDE in "${EXCLUDES[@]}"; do
    echo "Excluding: $EXCLUDE"
done

sudo btrfs filesystem defragment -r -clzo "$TARGET" \
    $(for d in "${EXCLUDES[@]}"; do echo "--exclude=$d"; done)

echo "Done!"

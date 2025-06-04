#!/usr/bin/env bash

# This script defragments and recompresses Btrfs subvolumes.

# Subvolumes
SUBVOLUMES=(
    "/"        # root
    "/home"    # home
    "/var/log" # log
)

for TARGET in "${SUBVOLUMES[@]}"; do
    echo "Processing: $TARGET"

    # Determine compression type
    if [[ "$TARGET" == "/" ]]; then
        COMP_TYPE="zstd"
    else
        COMP_TYPE="lzo"
    fi

    echo "Defragmenting and recompressing: $TARGET with $COMP_TYPE"
    sudo btrfs filesystem defragment -r -c"$COMP_TYPE" "$TARGET" || echo "Some files may be busy and will be skipped."

    echo "----------------------------------------"
done

echo "All done!"

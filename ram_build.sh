#!/bin/bash
[[ "$0" != *makepkg* && "$1" != *makepkg* ]] && exit 0
TMPFS_DIR="$HOME/.cache/rambuild"
[ ! -d "$TMPFS_DIR" ] && mkdir -p "$TMPFS_DIR" || exit 1
FREE_RAM=$(free -m | awk '/Mem:/ {print int($4*0.9)}')
[ $FREE_RAM -gt 58000 ] && FREE_RAM=58000
mountpoint -q "$TMPFS_DIR" || sudo mount -t tmpfs -o size="${FREE_RAM}m",mode=0755,uid=$(id -u),gid=$(id -g),noatime tmpfs "$TMPFS_DIR" || exit 1

export MAKEFLAGS="-j$(nproc)"

makepkg "$@"
MAKEPKG_STATUS=$?

[ $MAKEPKG_STATUS -eq 0 ] && find "$TMPFS_DIR" -type f -name "*.pkg.tar.*" -exec mv {} /var/cache/pacman/pkg/ \;

sudo umount "$TMPFS_DIR" 2>/dev/null
exit $MAKEPKG_STATUS

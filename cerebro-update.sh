#!/bin/bash
# cerebro-update.sh
set -euo pipefail

LOGFILE="/var/log/cerebro-update.log"
MARKER="/var/cache/cerebro-update.last"
THREE_DAYS=$((3*24*3600))  # 72h

# Create log file if it doesn't exist
if [ ! -f "$LOGFILE" ]; then
    sudo touch "$LOGFILE"
    sudo chmod 644 "$LOGFILE"
fi

# Create marker file if it doesn't exist
if [ ! -f "$MARKER" ]; then
    sudo touch "$MARKER"
    sudo chmod 644 "$MARKER"
fi

LAST_RUN=$(cat "$MARKER")
NOW=$(date +%s)
NEXT_RUN=$(( LAST_RUN + THREE_DAYS ))

# Skip if 3 days not passed
if (( NOW < NEXT_RUN )); then
    echo "[$(date)] Skipping update: next run at $(date -d "@$NEXT_RUN")." >> "$LOGFILE"
    exit 0
fi

# Sleep until 4AM if before 4AM
HOUR=$(date +%H)
if (( HOUR < 4 )); then
    SLEEP_SEC=$(( (4 - HOUR) * 3600 - $(date +%M) * 60 - $(date +%S) ))
    echo "[$(date)] Sleeping $SLEEP_SEC seconds until 4AM..." >> "$LOGFILE"
    sleep "$SLEEP_SEC"
fi

{
    echo "========== $(date) =========="
    echo "[*] Updating mirrorlist..."
    sudo reflector --country "Ukraine,Romania,Poland,Hungary,Bulgaria,Czech Republic,Lithuania,Latvia" \
                  --latest 20 --sort rate --protocol https \
                  --save /etc/pacman.d/mirrorlist


    echo "[*] Updating system packages..."
    sudo pacman -Sc --noconfirm && paru -Sc --noconfirm && sudo fstrim -av && sudo pacman -Syu --noconfirm --needed && paru -Syu --noconfirm --needed

    echo "[✓] Update finished at $(date)"
} >> "$LOGFILE" 2>&1

# Update marker
date +%s > "$MARKER"

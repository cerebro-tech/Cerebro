#!/usr/bin/env bash

set -euo pipefail

# Paths and config
INTERNAL_SNAPSHOT_DIR="/.snapshots"
EXTERNAL_MOUNT_POINT="/run/media/j/Backup_2T"
EXTERNAL_BACKUP_DIR="$EXTERNAL_MOUNT_POINT/btrfs_snapshots"
LOG_FILE="/home/j/my_scripts/backup_metrics.log"

SNAP_NAME="snap_$(date +'%Y-%m-%d')"

start_time=$(date +%s)

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting backup script..."

# Create metrics log file if missing
if [ ! -f "$LOG_FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating backup_metrics.log..."
    mkdir -p "$(dirname "$LOG_FILE")"
    cat > "$LOG_FILE" <<EOF
First Backup: N/A
Last Backup: N/A
Core Backup: N/A
Total Backups Created: 0
Total Internal Snapshots: 0
Total External Backups: 0
How long with U: 0 days
EOF
fi

# Remove old internal snapshot if exists
if sudo btrfs subvolume show "$INTERNAL_SNAPSHOT_DIR/$SNAP_NAME" &>/dev/null; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removing existing internal snapshot: $SNAP_NAME"
    sudo btrfs subvolume delete -c "$INTERNAL_SNAPSHOT_DIR/$SNAP_NAME"
fi

# Create new internal read-only snapshot
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating new read-only Btrfs snapshot: $SNAP_NAME"
sudo btrfs subvolume snapshot -r / "$INTERNAL_SNAPSHOT_DIR/$SNAP_NAME"

# External backup via btrfs send/receive if mounted
if mountpoint -q "$EXTERNAL_MOUNT_POINT"; then
    mkdir -p "$EXTERNAL_BACKUP_DIR"
    # Remove old external snapshot if exists
    if sudo btrfs subvolume show "$EXTERNAL_BACKUP_DIR/$SNAP_NAME" &>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Removing existing external snapshot: $SNAP_NAME"
        sudo btrfs subvolume delete -c "$EXTERNAL_BACKUP_DIR/$SNAP_NAME"
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Sending snapshot to external device: $SNAP_NAME"
    sudo btrfs send "$INTERNAL_SNAPSHOT_DIR/$SNAP_NAME" | sudo btrfs receive "$EXTERNAL_BACKUP_DIR"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] External backup device not mounted at $EXTERNAL_MOUNT_POINT, skipping external backup"
fi

# Gather metrics info
BACKUP_DATE=$(date +'%Y-%m-%d')
BACKUP_TIME=$(date +'%H:%M:%S')
BACKUP_SIZE=$(sudo du -sh "$INTERNAL_SNAPSHOT_DIR/$SNAP_NAME" | awk '{print $1}')

# Update metrics log
if grep -q "First Backup: N/A" "$LOG_FILE"; then
    sed -i "s|First Backup: N/A|First Backup: Date: $BACKUP_DATE, Time: $BACKUP_TIME, Size: $BACKUP_SIZE|" "$LOG_FILE"
    FIRST_BACKUP_DATE=$BACKUP_DATE
else
    FIRST_BACKUP_DATE=$(grep "First Backup:" "$LOG_FILE" | awk -F'Date: ' '{print $2}' | awk -F',' '{print $1}')
fi

sed -i "s|Last Backup:.*|Last Backup: Date: $BACKUP_DATE, Time: $BACKUP_TIME, Size: $BACKUP_SIZE|" "$LOG_FILE"

TOTAL_BACKUPS=$(grep "Total Backups Created:" "$LOG_FILE" | awk '{print $4}')
TOTAL_BACKUPS=$((TOTAL_BACKUPS + 1))
sed -i "s|Total Backups Created:.*|Total Backups Created: $TOTAL_BACKUPS|" "$LOG_FILE"

# Update core backup every 10 backups
if (( TOTAL_BACKUPS % 10 == 0 )); then
    sed -i "s|Core Backup:.*|Core Backup: Date: $BACKUP_DATE, Time: $BACKUP_TIME, Size: $BACKUP_SIZE|" "$LOG_FILE"
fi

# Count internal snapshots
TOTAL_INTERNAL=$(sudo ls "$INTERNAL_SNAPSHOT_DIR" | grep "^snap_" | wc -l)
sed -i "s|Total Internal Snapshots:.*|Total Internal Snapshots: $TOTAL_INTERNAL|" "$LOG_FILE"

# Count external backups
if mountpoint -q "$EXTERNAL_MOUNT_POINT"; then
    TOTAL_EXTERNAL=$(sudo ls "$EXTERNAL_BACKUP_DIR" | grep "^snap_" | wc -l)
else
    TOTAL_EXTERNAL=0
fi
sed -i "s|Total External Backups:.*|Total External Backups: $TOTAL_EXTERNAL|" "$LOG_FILE"

# Calculate days with U
if [ -n "$FIRST_BACKUP_DATE" ]; then
    DAYS_WITH_U=$(( ( $(date -d "$BACKUP_DATE" +%s) - $(date -d "$FIRST_BACKUP_DATE" +%s) ) / 86400 ))
    sed -i "s|How long with U:.*|How long with U: $DAYS_WITH_U days|" "$LOG_FILE"
fi

end_time=$(date +%s)
duration=$((end_time - start_time))

echo "[$(date '+%Y-%m-%d %H:%M:%S')] === Backup completed successfully in $duration seconds ==="
echo
echo "=== Backup Metrics Summary ==="
cat "$LOG_FILE"
echo "Backup Duration: $duration seconds"

exit 0

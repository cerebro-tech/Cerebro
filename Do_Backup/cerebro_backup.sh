#!/usr/bin/env bash

set -e

# === Setup ===
CORE_SNAP_NAME="snap_core"
LOG_FILE="/home/j/my_scripts/sripts_log/cerebro_backup.log"
SNAPSHOT_DIR="/.snapshots"
MOUNT_DIR="/run/media/j"
EXTERNAL_BKP_DIR_NAME="dobackup"
BOOT_PARTITION="/boot"

# Ensure log file exists
[[ -f "$LOG_FILE" ]] || touch "$LOG_FILE"

# Determine mode
if [[ "${1:-}" == "core" ]]; then
  SNAP_NAME="$CORE_SNAP_NAME"
  echo "[$(date +'%F %T')] Running in CORE mode: $SNAP_NAME"
else
  SNAP_NAME="snap_$(date +'%Y-%m-%d')"
  echo "[$(date +'%F %T')] Running in NORMAL mode: $SNAP_NAME"
fi

echo "[$(date +'%F %T')] Starting backup script..."

# === Create new read-only snapshot ===
echo "[$(date +'%F %T')] Creating new read-only Btrfs snapshot: $SNAP_NAME"
btrfs subvolume delete "$SNAPSHOT_DIR/$SNAP_NAME" &>/dev/null || true
btrfs subvolume snapshot -r / "$SNAPSHOT_DIR/$SNAP_NAME"
echo "[$(date +'%F %T')] Snapshot $SNAP_NAME created in $SNAPSHOT_DIR"

# === Find external Btrfs device with dobackup dir ===
EXTERNAL_DEV=""
for dev in "$MOUNT_DIR"/*; do
  if [[ -d "$dev/$EXTERNAL_BKP_DIR_NAME" ]]; then
    if [[ $(stat -f -c %T "$dev") == "btrfs" ]]; then
      EXTERNAL_DEV="$dev"
      echo "[$(date +'%F %T')] Found external device: $EXTERNAL_DEV"
      break
    fi
  fi
done

if [[ -z "$EXTERNAL_DEV" ]]; then
  echo "[$(date +'%F %T')] No mounted external device with Btrfs under $MOUNT_DIR."
else
  # Check free space
  FREE_SPACE=$(df --output=avail "$EXTERNAL_DEV" | tail -1)
  SNAP_SIZE=$(btrfs subvolume show "$SNAPSHOT_DIR/$SNAP_NAME" | grep -i "Generation" | awk '{print $2}')

  # If not enough space, overwrite core if dobackup core
  if [[ "$FREE_SPACE" -lt 1048576 ]]; then
    if [[ "${1:-}" == "core" ]]; then
      echo "[$(date +'%F %T')] Not enough space. Rewriting core snapshot only."
    else
      echo "Ho-Ho-ho-hooooo FU )) U havent space.. but u should know magic word motfacr))))"
      exit 1
    fi
  fi

  # Delete oldest backup if > 2 backups exist
  SNAPSHOT_LIST=($(ls -t "$EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME"))
  if [[ ${#SNAPSHOT_LIST[@]} -ge 2 ]]; then
    OLDEST="${SNAPSHOT_LIST[-1]}"
    echo "[$(date +'%F %T')] Removing oldest external snapshot: $OLDEST"
    btrfs subvolume delete "$EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME/$OLDEST"
  fi

  # Create new snapshot on external
  echo "[$(date +'%F %T')] Sending snapshot to external device..."
  btrfs send "$SNAPSHOT_DIR/$SNAP_NAME" | pv -s 1G | btrfs receive "$EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME"
  echo "[$(date +'%F %T')] Snapshot $SNAP_NAME sent to $EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME"

  # Rsync /boot if needed
  if [[ -d "$EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME/boot_backup" ]]; then
    echo "[$(date +'%F %T')] Syncing /boot to external device..."
    rsync -a --info=progress2 --delete "$BOOT_PARTITION/" "$EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME/boot_backup/"
  fi
fi

# === Update Backup Metrics ===
last_backup_size=$(du -sh "$SNAPSHOT_DIR/$SNAP_NAME" | cut -f1)
last_backup_time=$(date +'%Y-%m-%d %H:%M:%S')
first_backup_time=$(grep -m 1 "First Backup:" "$LOG_FILE" | awk '{print $5}')

current_timestamp=$(date +%s)

if [[ -n "$first_backup_time" ]]; then
  how_long=$(( (current_timestamp - first_backup_time) / 86400 ))
else
  how_long="unknown"
  echo "First Backup: Date: $(date +'%Y-%m-%d'), Time: $(date +'%H:%M:%S')" >> "$LOG_FILE"
fi

echo "Last Backup: Date: $(date +'%Y-%m-%d'), Time: $(date +'%H:%M:%S'), Size: $last_backup_size" >> "$LOG_FILE"

echo "[$(date +'%F %T')] === Backup completed successfully in $(($(date +%s)-$current_timestamp)) seconds ==="
echo ""
echo "=== Backup Metrics Summary ==="
head -n 1 "$LOG_FILE"
echo "Last Backup: Date: $(date +'%Y-%m-%d'), Time: $(date +'%H:%M:%S'), Size: $last_backup_size"
echo "Core Backup: $(grep 'core' "$LOG_FILE" | tail -1)"
echo "Total Backups Created: $(wc -l < "$LOG_FILE")"
echo "Total Internal Snapshots: $(ls -1 $SNAPSHOT_DIR | wc -l)"
echo "Total External Backups: $(ls -1 "$EXTERNAL_DEV/$EXTERNAL_BKP_DIR_NAME" 2>/dev/null | wc -l)"
echo "How long with U: $how_long days"

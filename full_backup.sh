#!/usr/bin/env bash

# Path setup
SCRIPT_DIR="/home/j/my_scripts"
LOG_FILE="${SCRIPT_DIR}/backup_metrics.log"
INTERNAL_SNAP_DIR="/.snapshots"
CORE_SNAP_NAME="snap_core"
BACKUP_NAME="snap_$(date +'%Y-%m-%d')"
START_TIME=$(date +%s)

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting backup script..."

# Determine snapshot name
if [[ "${1:-}" == "core" ]]; then
  SNAP_NAME="$CORE_SNAP_NAME"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Running in CORE mode: $SNAP_NAME"
else
  SNAP_NAME="$BACKUP_NAME"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Running in NORMAL mode: $SNAP_NAME"
fi

# Internal snapshot creation
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Creating new read-only Btrfs snapshot: $SNAP_NAME"
btrfs subvolume delete "${INTERNAL_SNAP_DIR}/${SNAP_NAME}" &>/dev/null || true
btrfs subvolume snapshot -r / "${INTERNAL_SNAP_DIR}/${SNAP_NAME}"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Snapshot $SNAP_NAME created in ${INTERNAL_SNAP_DIR}"

# External backups on Btrfs devices
for dev in /run/media/j/*; do
  [[ -d "$dev" ]] || continue
  fstype=$(findmnt -n -o FSTYPE --target "$dev")

  if [[ "$fstype" != "btrfs" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Skipping $dev (not Btrfs)."
    continue
  fi

  if [[ ! -d "$dev/dobackup" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Skipping $dev (no dobackup dir)."
    continue
  fi

  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Found external device: $dev"

  EXT_SNAP_DIR="$dev/btrfs_snapshots"
  EXT_SNAP_PATH="$EXT_SNAP_DIR/$SNAP_NAME"

  # Check free space (in bytes)
  FREE_SPACE=$(df --output=avail -B1 "$dev" | tail -1)
  MIN_FREE_SPACE=$((5 * 1024 * 1024 * 1024))  # 5 GiB

  if [[ "$FREE_SPACE" -lt "$MIN_FREE_SPACE" ]]; then
    if [[ "$SNAP_NAME" == "$CORE_SNAP_NAME" ]]; then
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Low space, rewriting core snapshot on $dev"
      # Remove old core
      btrfs subvolume delete "$EXT_SNAP_PATH" &>/dev/null || true
      # Send new snapshot
      mkdir -p "$EXT_SNAP_DIR"
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Sending snapshot (progress) to $EXT_SNAP_PATH"
      btrfs send -v "${INTERNAL_SNAP_DIR}/${SNAP_NAME}" | btrfs receive -v "$EXT_SNAP_DIR"
    else
      echo "Ho-Ho-ho-hooooo FU )) U havent space.. but u should know magic word motfacr))))"
      continue
    fi
  else
    # Remove old snapshot if exists
    btrfs subvolume delete "$EXT_SNAP_PATH" &>/dev/null || true
    # Keep only 2 snapshots (core + fresh)
    SNAP_COUNT=$(ls -1 "$EXT_SNAP_DIR" 2>/dev/null | wc -l)
    if (( SNAP_COUNT >= 2 )); then
      OLDEST=$(ls -1 "$EXT_SNAP_DIR" | grep -v "$CORE_SNAP_NAME" | head -n1)
      [[ -n "$OLDEST" ]] && btrfs subvolume delete "$EXT_SNAP_DIR/$OLDEST" &>/dev/null || true
    fi
    # Create snapshot on external device
    mkdir -p "$EXT_SNAP_DIR"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Sending snapshot (progress) to $EXT_SNAP_PATH"
    btrfs send -v "${INTERNAL_SNAP_DIR}/${SNAP_NAME}" | btrfs receive -v "$EXT_SNAP_DIR"
  fi

  # Rsync /boot if NOT core-only
  if [[ "$SNAP_NAME" != "$CORE_SNAP_NAME" ]]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backing up /boot to $dev/dobackup/boot_backup"
    mkdir -p "$dev/dobackup/boot_backup"
    rsync -aAXHv --info=progress2 --delete /boot/ "$dev/dobackup/boot_backup"
  fi
done

# Metrics
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
SIZE=$(btrfs filesystem usage -T / | grep "Used:" | awk '{print $2}')

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === Backup completed successfully in $DURATION seconds ==="
echo "
=== Backup Metrics Summary ===
First Backup: Date: $(head -n 1 $LOG_FILE | awk '{print $4}'), Time: $(head -n 1 $LOG_FILE | awk '{print $5}'), Size: 
Last Backup: Date: $(date +'%Y-%m-%d'), Time: $(date +'%H:%M:%S'), Size: $SIZE
Core Backup: Date: $(date +'%Y-%m-%d'), Time: $(date +'%H:%M:%S'), Size: $SIZE
Total Backups Created: $(grep -c 'Backup completed' $LOG_FILE)
Total Internal Snapshots: $(ls -1 $INTERNAL_SNAP_DIR | wc -l)
Total External Backups: $(ls -1 /run/media/j/*/btrfs_snapshots 2>/dev/null | wc -l)
How long with U: $(( ($(date +%s) - $(stat -c %Y $LOG_FILE)) / 86400 )) days
Backup Duration: $DURATION seconds
" >> $LOG_FILE

exit 0

#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

LOG_DIR="/home/j/my_scripts/sripts_log"
LOG_FILE="$LOG_DIR/cerebro_backup.log"
SCRIPT_DIR="/home/j/my_scripts/Do_Backup"
MINION_GIF="/home/j/my_scripts/gif/minon.gif"
CORE_SNAP_NAME="snap_core"

mkdir -p "$LOG_DIR"

function log() {
  echo "[$(date +'%F %T')] $*"
}

function get_first_backup_info() {
  grep '^First Backup:' "$LOG_FILE" 2>/dev/null || echo "First Backup: Date: -, Time: -, Size: -"
}

function get_last_backup_info() {
  grep '^Last Backup:' "$LOG_FILE" 2>/dev/null || echo "Last Backup: Date: -, Time: -, Size: -"
}

function get_core_backup_info() {
  grep '^Core Backup:' "$LOG_FILE" 2>/dev/null || echo "Core Backup: Date: -, Time: -, Size: -"
}

function get_metrics_summary() {
  grep -E 'Total Backups Created|Total Internal Snapshots|Total External Backups|How long with U' "$LOG_FILE" 2>/dev/null || echo "Metrics: N/A"
}

function get_backup_size() {
  local path=$1
  if [[ -e $path ]]; then
    du -sh "$path" 2>/dev/null | cut -f1
  else
    echo "-"
  fi
}

function free_space_kb() {
  df --output=avail -k "$1" 2>/dev/null | tail -1
}

function remove_old_snapshots() {
  local target_dir=$1
  local keep_core=$2
  local keep_fresh=$3

  find "$target_dir" -mindepth 1 -maxdepth 1 -type d ! -name "$keep_core" ! -name "$keep_fresh" -exec btrfs subvolume delete {} + 2>/dev/null || true
}

function remove_old_backups() {
  local backup_dir=$1
  local keep_core=$2
  local keep_fresh=$3

  find "$backup_dir" -maxdepth 1 -type f ! -name "$keep_core" ! -name "$keep_fresh" -exec rm -f {} + 2>/dev/null || true
}

function print_backup_metrics() {
  echo
  echo "=== Backup Metrics Summary (Last Entry Only) ==="
  tail -n 8 "$LOG_FILE"
  echo "Backup Duration: $BACKUP_DURATION seconds"
}

function main() {
  local mode="${1:-normal}"
  local start_time=$(date +%s)

  if [[ "$mode" == "core" ]]; then
    SNAP_NAME="$CORE_SNAP_NAME"
    log "Running in CORE mode: $SNAP_NAME"
  else
    SNAP_NAME="snap_$(date +'%Y-%m-%d')"
    log "Running in NORMAL mode: $SNAP_NAME"
  fi

  if [[ -d "/.snapshots/$SNAP_NAME" ]]; then
    log "Removing existing internal snapshot: $SNAP_NAME"
    sudo btrfs subvolume delete "/.snapshots/$SNAP_NAME"
  fi

  log "Creating new read-only Btrfs snapshot: $SNAP_NAME"
  sudo btrfs subvolume snapshot -r / "/.snapshots/$SNAP_NAME"
  log "Snapshot $SNAP_NAME created in /.snapshots"

  local ext_dev=""
  local ext_btrfs_snapshots_dir=""
  for mount_point in /run/media/j/*; do
    if [[ -d "$mount_point/dobackup" ]]; then
      local fs_type=$(findmnt -n -o FSTYPE --target "$mount_point")
      if [[ "$fs_type" == "btrfs" ]]; then
        ext_dev="$mount_point"
        ext_btrfs_snapshots_dir="$ext_dev/dobackup/btrfs_snapshots"
        break
      fi
    fi
  done

  if [[ -z "$ext_dev" ]]; then
    log "No mounted external device with btrfs and 'dobackup' folder found, skipping external backup"
  else
    local EXT_FREE
    EXT_FREE=$(free_space_kb "$ext_dev")

    mkdir -p "$ext_btrfs_snapshots_dir"

    local fresh_snap_name="snap_$(date +'%Y-%m-%d')"
    local fresh_exists=0
    if [[ -d "$ext_btrfs_snapshots_dir/$fresh_snap_name" ]]; then
      fresh_exists=1
    fi

    local core_exists=0
    if [[ -d "$ext_btrfs_snapshots_dir/$CORE_SNAP_NAME" ]]; then
      core_exists=1
    fi

    local SIZE_THRESHOLD=1048576

    if (( EXT_FREE < SIZE_THRESHOLD )); then
      if [[ "$mode" == "core" ]]; then
        log "Not enough space on external device. Rewriting core snapshot only."
        if [[ $core_exists -eq 1 ]]; then
          sudo btrfs subvolume delete "$ext_btrfs_snapshots_dir/$CORE_SNAP_NAME"
        fi
        log "Sending core snapshot to external device..."
        sudo btrfs send "/.snapshots/$SNAP_NAME" | sudo btrfs receive "$ext_btrfs_snapshots_dir"
      else
        if command -v chafa &>/dev/null; then
          chafa --animate=on "$MINION_GIF" &
          CHAFAPID=$!
          sleep 3
          kill "$CHAFAPID" 2>/dev/null || true
          wait "$CHAFAPID" 2>/dev/null || true
        else
          echo "[chafa not found, skipping animation]"
        fi
        echo "Ho-Ho-ho-ho.. FU =)) U haven't FREE space for this.. but U should know a magic word motherfacker =))"
      fi
    else
      remove_old_snapshots "$ext_btrfs_snapshots_dir" "$CORE_SNAP_NAME" "$fresh_snap_name"

      if [[ $fresh_exists -eq 1 ]]; then
        sudo btrfs subvolume delete "$ext_btrfs_snapshots_dir/$fresh_snap_name"
      fi

      log "Sending fresh snapshot $fresh_snap_name to external device..."
      sudo btrfs send "/.snapshots/$SNAP_NAME" | sudo btrfs receive "$ext_btrfs_snapshots_dir"

      local boot_src="/boot/"
      local boot_dst="$ext_dev/dobackup/boot_backup"

      mkdir -p "$boot_dst"
      log "Backing up /boot to external device via rsync..."
      rsync -a --info=progress2 "$boot_src" "$boot_dst"
    fi
  fi

  local end_time=$(date +%s)
  BACKUP_DURATION=$((end_time - start_time))

  {
    if ! grep -q '^First Backup:' "$LOG_FILE" 2>/dev/null; then
      echo "First Backup: Date: $(date +'%F'), Time: $(date +'%T'), Size: $(get_backup_size '/.snapshots')"
    fi
    echo "Last Backup: Date: $(date +'%F'), Time: $(date +'%T'), Size: $(get_backup_size '/.snapshots')"
    echo "Core Backup: Date: $(date +'%F'), Time: $(date +'%T'), Size: $(get_backup_size '/.snapshots/snap_core')"
    echo "Total Backups Created: $(find /.snapshots -mindepth 1 -maxdepth 1 -type d | wc -l)"
    echo "Total Internal Snapshots: $(find /.snapshots -mindepth 1 -maxdepth 1 -type d | wc -l)"
    echo "Total External Backups: $( [[ -d "$ext_btrfs_snapshots_dir" ]] && find "$ext_btrfs_snapshots_dir" -mindepth 1 -maxdepth 1 -type d | wc -l || echo 0 )"
    echo "How long with U: $(( ( $(date +%s) - $(date -d "$(stat -c %y /etc/passwd)" +%s) ) / 86400 )) days"
  } >>"$LOG_FILE"

  log "=== Backup completed successfully in $BACKUP_DURATION seconds ==="
  print_backup_metrics
}

main "$@"

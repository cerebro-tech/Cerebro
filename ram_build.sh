#!/usr/bin/env bash
# ~/cerebro_scripts/ram_build.sh
set -euo pipefail

# --- Detect total RAM and set limits ---
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
# Use TOTAL_RAM - 1.5G for build
BUILD_RAM_MB=$(( TOTAL_RAM_MB - 1536 ))
BUILD_RAM_MB=$(( BUILD_RAM_MB > 512 ? BUILD_RAM_MB : 512 ))  # minimum 512MB
TMP_BUILD_DIR="/dev/shm/ram_build"

mkdir -p "$TMP_BUILD_DIR"

log_file="$TMP_BUILD_DIR/ram_build-paru.log"

# --- Function to compile in RAM ---
build_in_ram() {
    local src_dir="$1"
    local install_cmd="$2"

    if [ ! -d "$src_dir" ]; then
        echo "[!] Source directory $src_dir not found" | tee -a "$log_file"
        return 1
    fi

    echo "[*] Copying source to RAM..." | tee -a "$log_file"
    rsync -a "$src_dir/" "$TMP_BUILD_DIR/src/"

    pushd "$TMP_BUILD_DIR/src" >/dev/null

    echo "[*] Starting build in RAM..." | tee -a "$log_file"
    mkdir -p build && cd build
    cmake .. -DCMAKE_BUILD_TYPE=Release
    ninja -j"$(( BUILD_RAM_MB / 2 ))"
    $install_cmd | tee -a "$log_file"

    popd >/dev/null
    echo "[*] Cleaning RAM build..." | tee -a "$log_file"
    rm -rf "$TMP_BUILD_DIR/src"
}

# --- Setup ZRAM and SWAP ---
if [[ "$1" == "--setup-ram" ]]; then
    # Determine swap partitions
    SWAP_ACTIVE=$(swapon --show=NAME | wc -l)
    echo "[*] Setting up ZRAM and Swap..." | tee -a "$log_file"
    sudo modprobe zram num_devices=1
    echo $(( TOTAL_RAM_MB / 2 ))M | sudo tee /sys/block/zram0/disksize
    sudo mkswap /dev/zram0
    if [ "$SWAP_ACTIVE" -gt 0 ]; then
        sudo swapon --priority 50 /dev/zram0
    else
        sudo swapon /dev/zram0
    fi
    exit 0
fi

# --- Compile Paru if missing ---
if [[ "$1" == "--compile-paru" ]]; then
    if ! command -v paru &>/dev/null; then
        echo "[*] Paru not found. Compiling in RAM..." | tee -a "$log_file"
        mkdir -p "$TMP_BUILD_DIR/paru"
        git clone https://aur.archlinux.org/paru.git "$TMP_BUILD_DIR/paru"
        build_in_ram "$TMP_BUILD_DIR/paru" "makepkg -si --noconfirm"
        echo "[*] Paru installed." | tee -a "$log_file"
    else
        echo "[*] Paru already installed." | tee -a "$log_file"
    fi
    exit 0
fi

# --- General build command ---
if [[ $# -ge 1 ]]; then
    SRC_DIR="$1"
    shift
    build_in_ram "$SRC_DIR" "$@"
else
    echo "Usage: $0 <source_dir> <install_command>"
    echo "       $0 --setup-ram"
    echo "       $0 --compile-paru"
    exit 1
fi

#!/usr/bin/env bash
# RAM-aware build script for AUR or local CMake projects
# Supports tmpfs builds, Ninja, ccache, mold, logs, and auto-source detection

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# 1️⃣ Detect available RAM
# -------------------------
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2 * 1024}')
MIN_RAM=$((3 * 1024 * 1024 * 1024))   # Minimum RAM for tmpfs build
USE_RAM=$((TOTAL_MEM - 1500*1024*1024)) # RAM for tmpfs build = total RAM - 1.5GB

# -------------------------
# 2️⃣ Setup build directories
# -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUILD_DIR="/tmp/ram_build"
LOG_FILE="$BUILD_DIR/ram_build-paru.log"

mkdir -p "$BUILD_DIR"
echo "[*] Log file: $LOG_FILE"

# -------------------------
# 3️⃣ Detect source directory automatically
# -------------------------
if [[ -f "PKGBUILD" ]]; then
    SRC_DIR=$(pwd)
elif [[ -d ".git" ]]; then
    SRC_DIR=$(pwd)
else
    echo "[!] Source folder not detected, specify manually."
    read -rp "Enter source folder path: " SRC_DIR
fi

echo "[*] Source folder: $SRC_DIR"

# -------------------------
# 4️⃣ Setup environment
# -------------------------
export CCACHE_DIR="$HOME/.ccache"
export CC="ccache gcc"
export CXX="ccache g++"
export PATH="/usr/lib/mold:$PATH"
mkdir -p "$CCACHE_DIR"

# -------------------------
# 5️⃣ Build in RAM or disk
# -------------------------
if (( TOTAL_MEM >= MIN_RAM )); then
    echo "[*] Enough RAM ($((TOTAL_MEM/1024/1024)) MB), building in tmpfs..."
    TMP_BUILD="$BUILD_DIR/$(basename "$SRC_DIR")"
    mkdir -p "$TMP_BUILD"
    rsync -a --exclude '*.git' "$SRC_DIR/" "$TMP_BUILD/"
    cd "$TMP_BUILD"
else
    echo "[*] Low RAM ($((TOTAL_MEM/1024/1024)) MB), building on disk..."
    cd "$SRC_DIR"
fi

# -------------------------
# 6️⃣ Run CMake / Make
# -------------------------
if [[ -f "CMakeLists.txt" ]]; then
    echo "[*] CMake project detected, using Ninja + mold..."
    cmake -B build -S . -G Ninja
    ninja -C build | tee -a "$LOG_FILE"
else
    echo "[*] No CMake detected, running make with mold..."
    make -j"$(nproc)" | tee -a "$LOG_FILE"
fi

# -------------------------
# 7️⃣ Install built package if applicable
# -------------------------
if [[ -f "*.pkg.tar.zst" ]] || [[ -f "*.deb" ]]; then
    echo "[*] Installing package..."
    sudo pacman -U *.pkg.tar.zst || sudo dpkg -i *.deb
fi

# -------------------------
# 8️⃣ Cleanup
# -------------------------
echo "[*] Build finished, cleaning tmpfs..."
if (( TOTAL_MEM >= MIN_RAM )); then
    rm -rf "$TMP_BUILD"
fi

# -------------------------
# 9️⃣ Source shell rc
# -------------------------
[[ -f ~/.bashrc ]] && source ~/.bashrc
[[ -f ~/.zshrc ]] && source ~/.zshrc

echo "[*] Done!"

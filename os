#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

echo "=== Cerebro General Installer — Final Version ==="
timedatectl set-ntp true

# -----------------------------
# Step 1: Detect CPU/GPU
# -----------------------------
CPU_VENDOR=$(lscpu | awk -F: '/Vendor ID/ {print $2}' | xargs)
GPU_INFO=$(lspci | grep -E "VGA|3D" | head -n1)
GPU_VENDOR=""
[[ $GPU_INFO =~ [Nn]VIDIA ]] && GPU_VENDOR="nvidia"
[[ $GPU_INFO =~ [Aa][Mm][Dd] ]] && GPU_VENDOR="amd"
[[ $GPU_INFO =~ [Ii]ntel ]] && GPU_VENDOR="intel"

MICROCODE_PKG=""
[[ "$CPU_VENDOR" == "GenuineIntel" ]] && MICROCODE_PKG="intel-ucode"
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && MICROCODE_PKG="amd-ucode"

echo "[Step 1] CPU Vendor: ${CPU_VENDOR:-Unknown}, GPU Vendor: ${GPU_VENDOR:-None}"
echo "[Step 1] Microcode package: ${MICROCODE_PKG:-None}"

# -----------------------------
# Step 2: Select installation disk
# -----------------------------
echo "[Step 2] Detecting available disks..."

# List all disks >= 32GB that are not mounted
AVAILABLE_DISKS=($(lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT | \
    awk '$3=="disk" && $2+0>=32 && $4=="" {print "/dev/" $1}'))

if [ ${#AVAILABLE_DISKS[@]} -eq 0 ]; then
    echo "Error: No disk >=32GB found."
    exit 1
elif [ ${#AVAILABLE_DISKS[@]} -eq 1 ]; then
    DISK="${AVAILABLE_DISKS[0]}"
    echo "Only one disk found, using $DISK"
else
    echo "Available disks:"
    for i in "${!AVAILABLE_DISKS[@]}"; do
        echo "[$i] ${AVAILABLE_DISKS[$i]}"
    done
    read -rp "Select disk [0-${#AVAILABLE_DISKS[@]}]: " DISK_IDX
    DISK="${AVAILABLE_DISKS[$DISK_IDX]}"
fi

# -----------------------------
# Step 3: Wipe disk
# -----------------------------
echo "[Step 3] Wiping disk..."
sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true
wipefs -a "$DISK" >/dev/null 2>&1 || true
partprobe "$DISK" || true

if [[ "$DISK" == /dev/nvme* ]] && command -v nvme >/dev/null; then
  read -rp "NVMe detected. Run nvme format -f? (y/N): " nvme_opt
  if [[ "$nvme_opt" =~ ^[Yy]$ ]]; then
    nvme format -f "$DISK" || true
    wipefs -a "$DISK" || true
    partprobe "$DISK" || true
  fi
fi

# -----------------------------
# Step 4: Partition sizes (boot=MB, others=GB)
# -----------------------------
echo "[Step 4] Partition sizes:"
read -rp "Enter /boot size (MB) [512]: " BOOT_MB
BOOT_MB=${BOOT_MB:-512}
(( BOOT_MB >= 512 )) || { echo "/boot must be >=512 MB."; exit 1; }

read -rp "Enter / size (GB) [44]: " ROOT_GB
ROOT_GB=${ROOT_GB:-44}
(( ROOT_GB >= 20 )) || { echo "/ must be >=20 GB."; exit 1; }

read -rp "Enter /home size (GB) [64]: " HOME_GB
HOME_GB=${HOME_GB:-64}
(( HOME_GB >= 10 )) || { echo "/home must be >=10 GB."; exit 1; }

read -rp "Enter swap size (GB) [28]: " SWAP_GB
SWAP_GB=${SWAP_GB:-28}
(( SWAP_GB >= 1 )) || { echo "swap must be >=1 GB."; exit 1; }

read -rp "Enter /data size (GB) [0 to skip, max to use remaining]: " DATA_IN
DATA_IN=${DATA_IN:-0}

ROOT_MB=$((ROOT_GB   * 1024))
HOME_MB=$((HOME_GB   * 1024))
SWAP_MB=$((SWAP_GB   * 1024))

TOTAL_MB=$(lsblk -bno SIZE "$DISK")
TOTAL_MB=$((TOTAL_MB / 1024 / 1024))
RES_MB=16
USED_MB=$((BOOT_MB + ROOT_MB + HOME_MB + SWAP_MB + RES_MB))
REMAIN_MB=$((TOTAL_MB - USED_MB))

if (( REMAIN_MB < 0 )); then
  echo "Sizes exceed disk capacity. Abort."
  exit 1
fi

if [[ "$DATA_IN" == max ]]; then
  if (( REMAIN_MB < 1024 )); then
    CREATE_DATA=false
  else
    DATA_MB=$REMAIN_MB
    CREATE_DATA=true
  fi
elif [[ "$DATA_IN" =~ ^[0-9]+$ ]] && ((DATA_IN > 0)); then
  DATA_MB=$((DATA_IN * 1024))
  if (( DATA_MB > REMAIN_MB )); then
    echo "/data too large. Abort."
    exit 1
  fi
  CREATE_DATA=true
else
  CREATE_DATA=false
fi

echo "[Step 4] Partition plan (MiB): boot=$BOOT_MB, root=$ROOT_MB, home=$HOME_MB, swap=$SWAP_MB, data=${CREATE_DATA:+$DATA_MB}"

# -----------------------------
# Step 5: Create partitions
# -----------------------------
echo "[Step 5] Creating partitions..."
sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true
sgdisk -n 1:0:+${BOOT_MB}M  -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:+${ROOT_MB}M  -t 2:8300 -c 2:"ROOT" "$DISK"
sgdisk -n 3:0:+${HOME_MB}M  -t 3:8300 -c 3:"HOME" "$DISK"
sgdisk -n 4:0:+${SWAP_MB}M  -t 4:8200 -c 4:"SWAP" "$DISK"
if $CREATE_DATA; then
  if [[ "$DATA_IN" == max ]]; then
    sgdisk -n 5:0:0           -t 5:8300 -c 5:"DATA" "$DISK"
  else
    sgdisk -n 5:0:+${DATA_MB}M -t 5:8300 -c 5:"DATA" "$DISK"
  fi
fi
partprobe "$DISK"
sleep 1

if [[ "$DISK" == *nvme* ]]; then
  ESP="${DISK}p1"; ROOT="${DISK}p2"; HOME="${DISK}p3"; SWAP="${DISK}p4"; DATA="${DISK}p5"
else
  ESP="${DISK}1"; ROOT="${DISK}2"; HOME="${DISK}3"; SWAP="${DISK}4"; DATA="${DISK}5"
fi

# -----------------------------
# Step 6: Format partitions
# -----------------------------
echo "[Step 6] Formatting..."
mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"
mkfs.ext4 -F "$HOME"
mkswap "$SWAP"
if $CREATE_DATA; then
  mkfs.xfs -f -m crc=1,finobt=1 -n ftype=1 "$DATA"
fi

# -----------------------------
# Step 7: Mount
# -----------------------------
echo "[Step 7] Mounting..."
mount "$ROOT" /mnt
mkdir -p /mnt/{boot,home,data}
mount "$ESP" /mnt/boot
mount "$HOME" /mnt/home
swapon "$SWAP"
$CREATE_DATA && mount "$DATA" /mnt/data

# -----------------------------
# Step 8: Install base + GNOME + tools
# -----------------------------
echo "[Step 8] Installing system..."
PACLIST=(
  base base-devel linux-zen linux-firmware ${MICROCODE_PKG}
  networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr
  xorg-server xorg-xinit xorg-xwayland
  gnome-shell gnome-session gnome-control-center
  gnome-terminal gnome-text-editor nautilus eog evince
  file-roller gnome-keyring gnome-backgrounds
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc
  xdg-user-dirs xdg-utils
  pipewire pipewire-alsa pipewire-pulse
  pipewire-jack wireplumber ly pigz mold ninja git
)

# Handle GPU packages safely
GPU_PKGS=()
if [ "$GPU_VENDOR" == "nvidia" ]; then
    GPU_PKGS=(nvidia nvidia-utils)
elif [ "$GPU_VENDOR" == "amd" ]; then
    GPU_PKGS=(xf86-video-amdgpu mesa)
elif [ "$GPU_VENDOR" == "intel" ]; then
    GPU_PKGS=(mesa)
fi

# Install all packages
pacstrap -K /mnt "${PACLIST[@]}" "${GPU_PKGS[@]}"


# -----------------------------
# Step 9: fstab
# -----------------------------
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# Step 10: ZRAM config
# -----------------------------
echo "[Step 10] Configuring ZRAM..."

# Detect total RAM in MiB (integer only)
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
echo "Detected RAM: ${MEM_MB} MiB"

# Ask user for ZRAM size in GB
read -rp "Enter ZRAM size in GB (0 = disable, default = RAM/6): " ZRAM_GB

# If user presses Enter, use default RAM/6
ZRAM_GB=${ZRAM_GB:-$(( MEM_MB / 1024 / 6 ))}

if [ "$ZRAM_GB" -gt 0 ]; then
    ZRAM_MB=$(( ZRAM_GB * 1024 ))
    echo "[Step 10] ZRAM size: ${ZRAM_MB} MiB"

    # Create ZRAM generator config inside new system
    mkdir -p /mnt/etc/systemd
    cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${ZRAM_MB}M
compression-algorithm = lz4
EOF

    echo "[Step 10] ZRAM configuration done."
else
    echo "[Step 10] ZRAM disabled by user."
fi

# --- Step 11: Build environment & system configuration ---

echo "🚀 Setting up build environment..."

# Initialize compilation flags safely to prevent unbound variable errors
: "${CFLAGS:=-O3 -march=native}"
: "${LDFLAGS:=}"

# Export variables for build processes
export CFLAGS LDFLAGS

# Detect number of cores for parallel make
NUM_CORES=$(nproc)

echo "💻 Using $NUM_CORES cores for compilation"
echo "🛠 CFLAGS: $CFLAGS"
echo "🛠 LDFLAGS: $LDFLAGS"

# Ensure required build tools are installed
echo "🔧 Installing build tools if missing..."
pacman -Sy --needed --noconfirm base-devel

# Prepare source directories
SRC_DIR="/mnt/arch_build/src"
BUILD_DIR="/mnt/arch_build/build"
mkdir -p "$SRC_DIR" "$BUILD_DIR"
cd "$SRC_DIR" || { echo "❌ Failed to enter $SRC_DIR"; exit 1; }

# Example: unpack source tarballs (existing logic unchanged)
for tarball in *.tar.*; do
    echo "📦 Extracting $tarball..."
    tar xf "$tarball" -C "$BUILD_DIR"
done

# Move into build directory
cd "$BUILD_DIR" || { echo "❌ Failed to enter $BUILD_DIR"; exit 1; }

# Start compilation (existing logic preserved)
echo "🔨 Starting compilation..."
make -j"$NUM_CORES"

echo "✅ Build environment setup completed."

# --- Locale & timezone setup ---

echo "🌍 Setting timezone and locale..."

# Set timezone based on IP, fallback to UTC
TIMEZONE=$(curl -s https://ipapi.co/timezone || echo "UTC")
if [ -n "$TIMEZONE" ] && [ -f "/usr/share/zoneinfo/$TIMEZONE" ]; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
else
    echo "⚠️ Timezone not found, defaulting to UTC"
    ln -sf /usr/share/zoneinfo/UTC /etc/localtime
fi

# Update hardware clock
hwclock --systohc

# Enable en_US.UTF-8 locale safely
if grep -q '^#en_US.UTF-8 UTF-8' /etc/locale.gen; then
    sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
fi

# Generate locale
locale-gen

# Set LANG environment variable
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "✅ Timezone and locale configured."


# -----------------------------
# Step 12: EFISTUB entries
# -----------------------------
echo "[Step 12] Creating EFISTUB entries..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
efibootmgr -c -d "$DISK" -p 1 -L "Cerebro (Zen)" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\\intel-ucode.img initrd=\\initramfs-linux-zen.img root=UUID=${ROOT_UUID} rw quiet resume=UUID=$(blkid -s UUID -o value "$SWAP")"

efibootmgr -c -d "$DISK" -p 1 -L "Cerebro (Zen + Booster)" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\\booster-linux-zen.img root=UUID=${ROOT_UUID} rw quiet resume=UUID=$(blkid -s UUID -o value "$SWAP")"

echo
echo "=== All Done! Installation complete. Reboot now. ==="

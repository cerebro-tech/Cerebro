#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

echo "[STEP 1] Updating keyrings and mirrorlist..."
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring reflector
reflector --country 'United States' --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

# -------------------------------
# Disk detection
# -------------------------------
echo "[STEP 2] Detecting disks >=32GB..."
DISKS=($(lsblk -dno NAME,SIZE | awk '$2+0 >= 32 {print "/dev/"$1}'))

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "No disks >=32GB found. Exiting."
    exit 1
elif [ ${#DISKS[@]} -eq 1 ]; then
    DISK=${DISKS[0]}
    echo "Single disk detected: $DISK, selecting automatically."
else
    echo "Available disks:"
    select DISK in "${DISKS[@]}"; do
        if [[ -n "$DISK" ]]; then
            echo "Selected $DISK"
            break
        fi
    done
fi

read -rp "Warning! All data on $DISK will be erased. Continue? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# -------------------------------
# Partitioning
# -------------------------------
echo "[STEP 3] Partitioning $DISK..."
if [[ "$DISK" =~ nvme ]]; then
    nvme format -f "$DISK" || true
fi
sgdisk --zap-all "$DISK" || true
wipefs -a "$DISK" || true

read -rp "Enter /boot size in MB (default 512): " BOOTSIZE
BOOTSIZE=${BOOTSIZE:-512}
read -rp "Enter / size in GB (default 64): " ROOTSIZE
ROOTSIZE=${ROOTSIZE:-64}
read -rp "Enter /home size in GB (default 128): " HOMESIZE
HOMESIZE=${HOMESIZE:-128}
read -rp "Enter /swap size in GB (default 32): " SWAPSIZE
SWAPSIZE=${SWAPSIZE:-32}
read -rp "Enter /data size in GB (0 = skip): " DATASIZE
DATASIZE=${DATASIZE:-0}

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB ${BOOTSIZE}MiB
parted -s "$DISK" set 1 boot on
parted -s "$DISK" mkpart root ext4 ${BOOTSIZE}MiB $((BOOTSIZE+ROOTSIZE))MiB
parted -s "$DISK" mkpart home ext4 $((BOOTSIZE+ROOTSIZE))MiB $((BOOTSIZE+ROOTSIZE+HOMESIZE))MiB
parted -s "$DISK" mkpart swap linux-swap $((BOOTSIZE+ROOTSIZE+HOMESIZE))MiB $((BOOTSIZE+ROOTSIZE+HOMESIZE+SWAPSIZE))MiB

if [ "$DATASIZE" -gt 0 ]; then
    parted -s "$DISK" mkpart data xfs $((BOOTSIZE+ROOTSIZE+HOMESIZE+SWAPSIZE))MiB 100%
    CREATE_DATA=1
else
    CREATE_DATA=0
fi

# -------------------------------
# Formatting
# -------------------------------
echo "[STEP 4] Formatting partitions..."
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"
mkfs.ext4 -F "${DISK}3"
mkswap "${DISK}4"
[ "$CREATE_DATA" -eq 1 ] && mkfs.xfs -f "${DISK}5"

# -------------------------------
# Mounting
# -------------------------------
echo "[STEP 5] Mounting partitions..."
mount "${DISK}2" /mnt
mkdir -p /mnt/{boot,home,swap}
mount "${DISK}1" /mnt/boot
mount "${DISK}3" /mnt/home
swapon "${DISK}4"
[ "$CREATE_DATA" -eq 1 ] && mkdir -p /mnt/data && mount "${DISK}5" /mnt/data

# -------------------------------
# CPU & GPU detection
# -------------------------------
CPU_VENDOR=$(lscpu | grep Vendor | awk '{print $3}')
GPU_VENDOR=$(lspci | grep -E "VGA|3D" | awk '{print $5}')

echo "[STEP 6] Detected CPU: $CPU_VENDOR, GPU: $GPU_VENDOR"

MICROCODE_PACKAGE=""
DRIVER_PACKAGES=""
[[ "$CPU_VENDOR" == "GenuineIntel" ]] && MICROCODE_PACKAGE="intel-ucode"
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && MICROCODE_PACKAGE="amd-ucode"
[[ "$GPU_VENDOR" == "Intel" ]] && DRIVER_PACKAGES+=" mesa xf86-video-intel "
[[ "$GPU_VENDOR" == "AMD" ]] && DRIVER_PACKAGES+=" mesa xf86-video-amdgpu "
[[ "$GPU_VENDOR" == "NVIDIA" ]] && DRIVER_PACKAGES+=" nvidia nvidia-utils nvidia-settings "

# -------------------------------
# Base system installation
# -------------------------------
echo "[STEP 7] Installing base system..."
pacstrap -K /mnt base base-devel linux-zen linux-firmware $MICROCODE_PACKAGE \
  networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr \
  xorg-server xorg-xinit xorg-xwayland \
  gnome-shell gnome-session gnome-control-center gnome-terminal gnome-text-editor \
  nautilus eog evince file-roller gnome-keyring gnome-backgrounds \
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
  xdg-user-dirs xdg-utils \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  ly $DRIVER_PACKAGES

# -------------------------------
# Fstab
# -------------------------------
genfstab -U /mnt >> /mnt/etc/fstab

# -------------------------------
# Chroot configuration
# -------------------------------
arch-chroot /mnt /bin/bash -c "
# Timezone auto-detect
ln -sf /usr/share/zoneinfo/\$(timedatectl | grep 'Time zone' | awk '{print \$3}') /etc/localtime
hwclock --systohc

# Locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

# Hostname
echo 'arch' > /etc/hostname

# Pacman configuration (enable multilib)
sed -i '/#\[multilib\]/,+1 s/#//' /etc/pacman.conf
pacman -Sy --noconfirm

# Install AUR helper and performance tools
pacman -Sy --noconfirm git
git clone https://aur.archlinux.org/paru.git /tmp/paru
cd /tmp/paru
makepkg -si --noconfirm
paru -S --noconfirm preload booster pigz mold ninja

# ZRAM
systemctl enable zram-generator

# Enable essential services
systemctl enable NetworkManager
systemctl enable ly

# Performance makepkg.conf
echo 'CFLAGS="-O2 -march=native -pipe -flto=auto"' >> /etc/makepkg.conf
echo 'CXXFLAGS="\$CFLAGS"' >> /etc/makepkg.conf
echo 'MAKEFLAGS="-j$(nproc)"' >> /etc/makepkg.conf
echo 'COMPRESSXZ=(xz -c -T0 -)' >> /etc/makepkg.conf
echo 'PKGDEST=/var/cache/pacman/pkg' >> /etc/makepkg.conf
"

# -------------------------------
# EFISTUB boot
# -------------------------------
BOOTUUID=$(blkid -s PARTUUID -o value "${DISK}2")
efibootmgr -c -d "$DISK" -p 1 -L "Arch Linux Zen" -l "\vmlinuz-linux-zen" -u "root=PARTUUID=$BOOTUUID rw initrd=\initramfs-linux-zen.img"
efibootmgr -c -d "$DISK" -p 1 -L "Arch Linux Zen Booster" -l "\vmlinuz-linux-zen" -u "root=PARTUUID=$BOOTUUID rw initrd=\booster-linux-zen.img"

echo "[INSTALLATION COMPLETE] Reboot the system."

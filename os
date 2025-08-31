#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ========================================
# Cerebro General-Purpose Arch Installer
# Supports: SATA/NVMe, EFISTUB, ZRAM, Ly, Booster
# Optimized for Intel CPUs
# ========================================

echo "[STEP 1] Updating keyrings and mirrorlist..."
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring reflector
reflector --country 'United States' --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

echo "[STEP 2] Detect available disks (>=32GB)..."
DISKS=($(lsblk -dno NAME,SIZE | awk '$2+0 >= 32 {print "/dev/"$1}'))
if [ ${#DISKS[@]} -eq 0 ]; then
    echo "No disks >=32GB found. Exiting."
    exit 1
fi

echo "Available disks:"
select DISK in "${DISKS[@]}"; do
    if [[ -n "$DISK" ]]; then
        echo "Selected $DISK"
        break
    fi
done

read -rp "Warning! All data on $DISK will be erased. Continue? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

echo "[STEP 3] Cleaning disk..."
if [[ "$DISK" =~ nvme ]]; then
    nvme format -f "$DISK" || true
fi
sgdisk --zap-all "$DISK" || true
wipefs -a "$DISK" || true

echo "[STEP 4] Partitioning disk..."
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 1GiB
parted -s "$DISK" set 1 boot on
parted -s "$DISK" mkpart root ext4 1GiB 33%
parted -s "$DISK" mkpart home ext4 33% 80%
parted -s "$DISK" mkpart swap linux-swap 80% 88%

read -rp "Enter /data size in GB (0 = skip, max = remaining space): " DATASIZE
if [ "$DATASIZE" -gt 0 ]; then
    parted -s "$DISK" mkpart data xfs 88% 100%
    CREATE_DATA=1
else
    CREATE_DATA=0
fi

echo "[STEP 5] Formatting partitions..."
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"
mkfs.ext4 -F "${DISK}3"
mkswap "${DISK}4"
if [ "$CREATE_DATA" -eq 1 ]; then
    mkfs.xfs -f "${DISK}5"
fi

echo "[STEP 6] Mounting partitions..."
mount "${DISK}2" /mnt
mkdir -p /mnt/{boot,home,swap}
mount "${DISK}1" /mnt/boot
mount "${DISK}3" /mnt/home
swapon "${DISK}4"
if [ "$CREATE_DATA" -eq 1 ]; then
    mkdir -p /mnt/data
    mount "${DISK}5" /mnt/data
fi

echo "[STEP 7] Install base system..."
pacstrap -K /mnt base base-devel linux-zen linux-firmware intel-ucode \
  networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr \
  xorg-server xorg-xinit xorg-xwayland \
  gnome-shell gnome-session gnome-control-center gnome-terminal gnome-text-editor \
  nautilus eog evince file-roller gnome-keyring gnome-backgrounds \
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
  xdg-user-dirs xdg-utils \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  ly

echo "[STEP 8] Generate fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

echo "[STEP 9] Chroot configuration..."
arch-chroot /mnt /bin/bash -c "
# Timezone
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

# Install chaotic-aur repo for preload
pacman -Sy --noconfirm git
git clone https://aur.archlinux.org/paru.git /tmp/paru
cd /tmp/paru
makepkg -si --noconfirm
pacman -Syu --noconfirm
paru -S --noconfirm preload booster pigz mold ninja

# ZRAM
systemctl enable zram-generator

# Enable services
systemctl enable NetworkManager
systemctl enable ly
"

echo "[STEP 10] EFISTUB boot entries..."
BOOTUUID=$(blkid -s PARTUUID -o value "${DISK}2")
efibootmgr -c -d "$DISK" -p 1 -L "Arch Linux Zen" -l "\vmlinuz-linux-zen" -u "root=PARTUUID=$BOOTUUID rw initrd=\initramfs-linux-zen.img"
efibootmgr -c -d "$DISK" -p 1 -L "Arch Linux Zen Booster" -l "\vmlinuz-linux-zen" -u "root=PARTUUID=$BOOTUUID rw initrd=\booster-linux-zen.img"

echo "[INSTALLATION COMPLETE] You can now reboot."

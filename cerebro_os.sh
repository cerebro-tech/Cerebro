#!/usr/bin/env bash
# Cerebro Arch Linux Auto-Installer (EFISTUB only, performance-tuned)
# Stack: Arch Linux + Zen kernel + EFISTUB + Ly + GNOME minimal

set -euo pipefail

### --- CONFIG --- ###
HOSTNAME="cerebro"
USERNAME="j"
PASSWORD="777"

DISK=$(lsblk -d -o NAME,SIZE,TYPE | grep disk)
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL
read -rp "Enter target disk (example: nvme0n1 or sda): " DISK

BOOT_SIZE="1981M"
ROOT_SIZE="44G"
HOME_SIZE="64G"
SWAP_SIZE="28G"
DATA_FS="xfs"   # XFS for performance

### --- PARTITIONING --- ###
sgdisk --zap-all "/dev/$DISK"

# EFI
sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI" "/dev/$DISK"
# Root
sgdisk -n 2:0:+${ROOT_SIZE} -t 2:8300 -c 2:"ROOT" "/dev/$DISK"
# Home
sgdisk -n 3:0:+${HOME_SIZE} -t 3:8300 -c 3:"HOME" "/dev/$DISK"
# Swap
sgdisk -n 4:0:+${SWAP_SIZE} -t 4:8200 -c 4:"SWAP" "/dev/$DISK"
# Data (remaining)
sgdisk -n 5:0:0 -t 5:8300 -c 5:"DATA" "/dev/$DISK"

partprobe "/dev/$DISK"

### --- FORMATTING --- ###
mkfs.vfat -F32 "/dev/${DISK}1"
mkfs.xfs -f "/dev/${DISK}2"
mkfs.xfs -f "/dev/${DISK}3"
mkswap "/dev/${DISK}4"
mkfs.${DATA_FS} -f "/dev/${DISK}5"

### --- MOUNTING --- ###
mount "/dev/${DISK}2" /mnt
mkdir /mnt/{boot,home,data}
mount "/dev/${DISK}1" /mnt/boot
mount "/dev/${DISK}3" /mnt/home
mount "/dev/${DISK}5" /mnt/data
swapon "/dev/${DISK}4"

### --- INSTALL BASE SYSTEM --- ###
pacstrap -K /mnt base linux-zen linux-firmware efibootmgr xfsprogs nano sudo networkmanager

### --- FSTAB --- ###
genfstab -U /mnt >> /mnt/etc/fstab

### --- CHROOT --- ###
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Hosts
cat > /etc/hosts <<HST
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HST

# Users
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/99_wheel

# Initramfs
mkinitcpio -P

# Get UUIDs
ROOT_UUID=\$(blkid -s UUID -o value /dev/${DISK}2)
SWAP_UUID=\$(blkid -s UUID -o value /dev/${DISK}4)

# EFISTUB ENTRY
efibootmgr -c -d /dev/$DISK -p 1 \
  -L "Arch Linux Zen (Cerebro EFISTUB)" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\intel-ucode.img initrd=\initramfs-linux-zen.img root=UUID=\$ROOT_UUID rw quiet loglevel=3 mitigations=off intel_pstate=active resume=UUID=\$SWAP_UUID"

# Enable services
systemctl enable NetworkManager

# Install minimal GNOME + Ly
pacman --noconfirm -S gnome-shell gnome-control-center gnome-terminal \
  gnome-keyring nautilus sushi eog gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
  xdg-user-dirs xdg-utils ly pipewire pipewire-alsa pipewire-pulse pipewire-jack

# Remove unwanted GNOME packages
pacman -Rsn --noconfirm yelp gnome-tour gnome-user-docs totem malcontent \
  gnome-weather gnome-music gnome-maps gdm epiphany

systemctl enable ly.service
EOF

echo "✅ Installation complete. Reboot now."

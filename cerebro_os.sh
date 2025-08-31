#!/usr/bin/env bash
set -euo pipefail

echo "=== Cerebro Arch Linux Auto Installer (EFISTUB, Performance-Oriented) ==="

# -----------------------
# 1. Select Disk
# -----------------------
lsblk -dpno NAME,SIZE | grep -E "disk"
read -rp "Enter target disk (e.g., /dev/nvme0n1): " DISK

# Confirm
read -rp "!!! WARNING: This will ERASE $DISK. Continue? (yes/[no]): " CONFIRM
[[ "$CONFIRM" != "yes" ]] && { echo "Aborted."; exit 1; }

# -----------------------
# 2. Partition Sizes
# -----------------------
read -rp "Enter size for EFI partition (default 512M): " EFISIZE
EFISIZE=${EFISIZE:-512M}

read -rp "Enter size for ROOT (/) in GB (min 20): " ROOTSIZE
if (( ROOTSIZE < 20 )); then
    echo "❌ ROOT must be >= 20GB"
    exit 1
fi

read -rp "Enter size for HOME in GB (min 10): " HOMESIZE
if (( HOMESIZE < 10 )); then
    echo "❌ HOME must be >= 10GB"
    exit 1
fi

read -rp "Enter size for DATA in GB (0 to skip): " DATASIZE

# -----------------------
# 3. Partition Disk
# -----------------------
echo "[*] Partitioning $DISK..."
sgdisk --zap-all $DISK
partprobe $DISK

sgdisk -n1:0:+$EFISIZE -t1:ef00 -c1:"EFI" $DISK
sgdisk -n2:0:+${ROOTSIZE}G -t2:8300 -c2:"ROOT" $DISK
sgdisk -n3:0:+${HOMESIZE}G -t3:8300 -c3:"HOME" $DISK
if (( DATASIZE > 0 )); then
    sgdisk -n4:0:+${DATASIZE}G -t4:8300 -c4:"DATA" $DISK
fi
partprobe $DISK

# -----------------------
# 4. Filesystems
# -----------------------
echo "[*] Creating filesystems..."
mkfs.fat -F32 ${DISK}1
mkfs.ext4 -F ${DISK}2   # root
mkfs.ext4 -F ${DISK}3   # home
if (( DATASIZE > 0 )); then
    mkfs.xfs -f ${DISK}4
fi

# -----------------------
# 5. Mount Filesystems
# -----------------------
echo "[*] Mounting..."
mount ${DISK}2 /mnt
mkdir -p /mnt/{boot,home}
mount ${DISK}1 /mnt/boot
mount ${DISK}3 /mnt/home
if (( DATASIZE > 0 )); then
    mkdir -p /mnt/data
    mount ${DISK}4 /mnt/data
fi

# -----------------------
# 6. Base Install
# -----------------------
echo "[*] Installing base system and minimal GNOME..."
pacstrap /mnt base linux linux-firmware \
    gnome-shell gnome-control-center gnome-settings-daemon gdm \
    gnome-terminal gnome-text-editor nautilus sushi eog evince \
    gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
    xdg-user-dirs xdg-utils gnome-keyring gnome-backgrounds \
    pipewire pipewire-pulse wireplumber \
    networkmanager

# -----------------------
# 7. Fstab
# -----------------------
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------
# 8. Chroot Config
# -----------------------
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "[*] Setting timezone, locale, hostname..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "cerebro" > /etc/hostname

echo "[*] Setting root password..."
echo "root:root" | chpasswd

systemctl enable gdm NetworkManager

# -----------------------
# EFISTUB Bootloader
# -----------------------
echo "[*] Installing EFISTUB..."
bootctl install

UUID_ROOT=$(blkid -s UUID -o value ${DISK}2)
cat <<EOC > /boot/loader/entries/arch.conf
title   Arch Linux (Cerebro)
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=UUID=${UUID_ROOT} rw quiet splash
EOC

cat <<EOC > /boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
editor no
EOC

EOF

echo "=== Installation complete! Reboot and enjoy Cerebro Arch ==="

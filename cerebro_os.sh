#!/usr/bin/env bash
set -euo pipefail

### CONFIG ###
HOSTNAME="cerebro"
USERNAME="j"
USERPASS="777"
ROOTPASS="777"

BOOT_SIZE="1981M"
ROOT_SIZE="22G"
SWAP_SIZE="28G"
HOME_SIZE="32G"

### CHECK FOR DIALOG ###
if ! command -v dialog &>/dev/null; then
    echo "[*] Installing dialog for interactive menus..."
    pacman -Sy --noconfirm dialog
fi

### SELECT DISK ###
DISK=$(dialog --title "Select Target Disk" --menu "Available disks:" 15 60 4 \
    $(lsblk -d -n -o NAME,SIZE | awk '{print $1 " " $2}') 3>&1 1>&2 2>&3)
DISK="/dev/$DISK"

### SELECT /DATA SIZE ###
DATA_SIZE=$(dialog --inputbox "Enter /data size in GB:\n0 = no /data\nmax = use remaining space" 10 50 "0" 3>&1 1>&2 2>&3)

clear
echo "[*] Using disk: $DISK"
echo "[*] /data size: $DATA_SIZE"

### WIPE & CREATE PARTITIONS ###
echo "[*] Wiping $DISK..."
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI" $DISK
sgdisk -n 2:0:+${ROOT_SIZE} -t 2:8300 -c 2:"ROOT" $DISK
sgdisk -n 3:0:+${SWAP_SIZE} -t 3:8200 -c 3:"SWAP" $DISK
sgdisk -n 4:0:+${HOME_SIZE} -t 4:8300 -c 4:"HOME" $DISK

# DATA (conditional)
if [[ "$DATA_SIZE" != "0" ]]; then
    if [[ "$DATA_SIZE" == "max" ]]; then
        sgdisk -n 5:0:0 -t 5:8300 -c 5:"DATA" $DISK
    else
        sgdisk -n 5:0:+${DATA_SIZE}G -t 5:8300 -c 5:"DATA" $DISK
    fi
fi

partprobe "$DISK"
sleep 2

### FORMAT FILESYSTEMS ###
echo "[*] Formatting filesystems..."
mkfs.fat -F32 ${DISK}1
mkfs.ext4 -f ${DISK}2
mkswap ${DISK}3
mkfs.ext4 -f ${DISK}4
if [[ "$DATA_SIZE" != "0" ]]; then
    mkfs.xfs -f -m crc=1,finobt=1 -n ftype=1 ${DISK}5
fi

### MOUNT FILESYSTEMS ###
echo "[*] Mounting filesystems..."
mount ${DISK}2 /mnt
mkdir /mnt/{boot,home}
mount ${DISK}1 /mnt/boot
mount ${DISK}4 /mnt/home
swapon ${DISK}3
if [[ "$DATA_SIZE" != "0" ]]; then
    mkdir /mnt/data
    mount ${DISK}5 /mnt/data
fi

### BASE SYSTEM INSTALL ###
echo "[*] Installing base system..."
pacstrap /mnt base linux-zen linux-firmware intel-ucode \
    xfsprogs efibootmgr vim sudo networkmanager

genfstab -U /mnt >> /mnt/etc/fstab

### CHROOT ###
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

echo "[*] Setting hostname..."
echo "$HOSTNAME" > /etc/hostname

echo "[*] Setting hosts..."
cat <<HST > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HST

echo "[*] Setting timezone..."
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
hwclock --systohc

echo "[*] Locale..."
sed -i 's/#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "[*] Setting root password..."
echo "root:$ROOTPASS" | chpasswd

echo "[*] Creating user..."
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USERPASS" | chpasswd
sed -i 's/# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

### GNOME MINIMAL ###
echo "[*] Installing GNOME minimal..."
pacman -S --needed --noconfirm gnome-control-center gnome-shell gnome-session \
    gnome-terminal nautilus gnome-text-editor eog evince file-roller \
    gnome-system-monitor gnome-calculator seahorse sushi gvfs gvfs-mtp

### Remove unwanted GNOME apps ###
pacman -R --noconfirm yelp gnome-tour gnome-user-docs totem malcontent \
    gnome-weather gnome-music gnome-maps gdm epiphany

### Install Ly Display Manager ###
pacman -S --needed --noconfirm ly
systemctl enable ly.service

### EFISTUB BOOT ENTRY ###
echo "[*] Configuring EFISTUB boot..."
ROOT_UUID=\$(blkid -s UUID -o value ${DISK}2)
SWAP_UUID=\$(blkid -s UUID -o value ${DISK}3)

efibootmgr -c -d $DISK -p 1 \
  -L "Arch Linux (Zen, EFISTUB)" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\intel-ucode.img initrd=\initramfs-linux-zen.img root=UUID=\$ROOT_UUID rw quiet resume=UUID=\$SWAP_UUID"
EOF

echo "[*] Installation finished. You can reboot now."

#!/usr/bin/env bash
set -euo pipefail

# ============================
# VARIABLES
# ============================
DISK="/dev/nvme0n1"
MNT="/mnt"

# 1. PARTITIONING
echo "=== 1. Creating partitions ==="
sgdisk --zap-all "$DISK"
sgdisk -n1:0:+1981M -t1:EF00 -c1:"BOOT" "$DISK"
sgdisk -n2:0:+32G -t2:8300 -c2:"ROOT" "$DISK"
sgdisk -n3:0:+32G -t3:8200 -c3:"SWAP" "$DISK"
sgdisk -n4:0:+12G -t4:8300 -c4:"VARCACHE" "$DISK"
sgdisk -n5:0:+8G -t5:8300 -c5:"VARLOG" "$DISK"
sgdisk -n6:0:+8G -t6:8300 -c6:"VARLIB" "$DISK"
sgdisk -n7:0:+22G -t7:8300 -c7:"HOME" "$DISK"
sgdisk -n8:0:+24G -t8:8300 -c8:"BUILDS" "$DISK"
sgdisk -n9:0:0 -t9:8300 -c9:"DATA" "$DISK"
sgdisk -p "$DISK"

# 2. FORMAT PARTITIONS
echo "=== 2. Formatting partitions ==="
mkfs.fat -F32 "${DISK}p1" -n BOOT
mkfs.f2fs -f -l ROOT "${DISK}p2"
mkswap -L SWAP "${DISK}p3"
mkfs.f2fs -f -l VARCACHE "${DISK}p4"
mkfs.f2fs -f -l VARLOG "${DISK}p5"
mkfs.f2fs -f -l VARLIB "${DISK}p6"
mkfs.f2fs -f -l HOME "${DISK}p7"
mkfs.f2fs -f -l BUILDS "${DISK}p8"
mkfs.xfs -f -L DATA "${DISK}p9"

# 3. MOUNT PARTITIONS
echo "=== 3. Mounting partitions ==="
mount "${DISK}p2" "$MNT"
swapon "${DISK}p3"
mkdir -p $MNT/{boot,var/cache,var/log,var/lib,home,builds,data}
mount -t vfat "${DISK}p1" "$MNT/boot"
mount -t f2fs "${DISK}p4" "$MNT/var/cache"
mount -t f2fs "${DISK}p5" "$MNT/var/log"
mount -t f2fs "${DISK}p6" "$MNT/var/lib"
mount -t f2fs "${DISK}p7" "$MNT/home"
mount -t f2fs "${DISK}p8" "$MNT/builds"
mount -t xfs "${DISK}p9" "$MNT/data"

# 4. INSTALL BASE SYSTEM
echo "=== 4. Installing base system + packages ==="
pacstrap /mnt \
  base base-devel \
  linux-lts \
  linux-firmware \
  sudo nano \
  efibootmgr intel-ucode \
  ly zsh \
  gnome-shell gnome-desktop-4 gnome-session gnome-settings-daemon mutter gnome-control-center gnome-console gnome-system-monitor gnome-text-editor \
  networkmanager \
  gnome-keyring nautilus \
  pipewire wireplumber pipewire-pulse pipewire-alsa pipewire-jack \
  xdg-desktop-portal xdg-desktop-portal-gnome xdg-utils \
  xorg-xwayland \
  ccache mold ninja

# 5. GENERATE FSTAB
echo "=== 5. Generating fstab ==="
genfstab -U $MNT >> $MNT/etc/fstab
cat >> /mnt/etc/fstab <<EOF
tmpfs   /tmp    tmpfs   size=100%,mode=1777,noatime 0 0
EOF

# 6. CHROOT INTO NEW SYSTEM
echo "=== 6. Chrooting into new system ==="
arch-chroot $MNT /bin/bash <<'EOF'

# ----------------------------
# 6.1 CONFIGURE mkinitcpio
# ----------------------------
echo "=== Configuring mkinitcpio ==="
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block filesystems keyboard resume fsck)/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION="lz4"/COMPRESSION="lz4"/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-T0)/' /etc/mkinitcpio.conf
sed -i "s/^PRESETS=('default' 'fallback')/PRESETS=('default')/" /etc/mkinitcpio.d/linux.preset
mkinitcpio -P
rm -f /boot/initramfs-*-fallback.img

# 6.2 SET EFISTUB BOOT ENTRY
echo "=== Setting EFISTUB boot entry ==="
efibootmgr -c -d /dev/nvme0n1 -p 1 -L "Cerebro LTS IntelGPU" -l "\vmlinuz-linux-lts" \
  -u "root=LABEL=ROOT resume=LABEL=SWAP rw rootfstype=f2fs rootflags=compress_algorithm=lz4,compress_chksum loglevel=3 quiet initrd=\initramfs-linux-lts.img"

# 6.3 HOSTNAME & NETWORK
echo "cerebro" > /etc/hostname
cat > /etc/hosts <<EOL

# 6.4 CREATE USER
useradd -m -G wheel -s /bin/zsh j
echo "j:123" | chpasswd
sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers

# 7 Enable services
systemctl enable NetworkManager
systemctl enable ly
EOF

# 8. FINALIZE INSTALLATION
echo "=== 7. Finalizing installation ==="
sync
umount -R /mnt
swapoff -a
echo "Installation complete. Reboot into your new Cerebro OS!"

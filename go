#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
MNT="/mnt"
USERNAME="j"
PASSWORD="ppp" 

echo "==> 0. Enabling NTP"
timedatectl set-ntp true

echo "==> 1. Secure erase + setting the block size to 4KB"
nvme format --ses=1 --lbaf=1 $DISK

sgdisk -n1:0:+1981M -t1:EF00 -c1:"BOOT" "$DISK"
sgdisk -n2:0:+40G -t2:8300 -c2:"ROOT" "$DISK"
sgdisk -n3:0:+16G -t5:8300 -c3:"VARLIB" "$DISK"
sgdisk -n4:0:+24G -t6:8300 -c4:"HOME" "$DISK"
sgdisk -n5:0:+18G -t7:8300 -c5:"BUILDS" "$DISK"
sgdisk -n6:0:0 -t8:8300 -c6:"DATA" "$DISK"
sgdisk -p "$DISK"

echo "==> 2. Formatting partitions"
mkfs.fat -n BOOT -F32 "${DISK}p1"
mkfs.f2fs -l ROOT -f -O extra_attr,inode_checksum,sb_checksum,compression "${DISK}p2"
mkfs.xfs -L VARLIB -f "${DISK}p3"
mkfs.f2fs -l HOME -f -O extra_attr,inode_checksum,sb_checksum,compression "${DISK}p4"
mkfs.xfs -L BUILDS "${DISK}p5"
mkfs.xfs -L DATA -f "${DISK}p6"

echo "==>3. Mounting partitions"
mount -t f2fs -o noatime,nodiratime,compress_algorithm=lz4,compress_chksum,discard,inline_xattr,inline_data,inline_dentry,ssd "${DISK}p2" /mnt
mkdir -p /mnt/{boot,var/lib,home,builds,data}
mount -t vfat -o noatime,nodiratime,umask=0077,iocharset=utf8,errors=remount-ro "${DISK}p1" /mnt/boot
mount -t xfs -o noatime,nodiratime,discard,inode64 "${DISK}p6" /mnt/var/lib
mount -t f2fs -o noatime,nodiratime,compress_algorithm=lz4,compress_chksum,discard,inline_xattr,inline_data,inline_dentry,ssd "${DISK}p7" /mnt/home
mount -t xfs -o noatime,nodiratime,discard,inode64 "${DISK}p8" /mnt/builds
mount -t xfs -o noatime,nodiratime,inode64,logbsize=64k "${DISK}p9" /mnt/data


echo "==>4. Installing base system + packages"
pacstrap /mnt \
  base base-devel \
  linux-lts linux-lts-headers \
  xfsprogs f2fs-tools dosfstools \
  efibootmgr sudo nano zsh \
  intel-ucode nvidia-dkms nvidia-utils \
  networkmanager ly \
  gnome-shell gnome-desktop-4 mutter gnome-session gnome-control-center gnome-settings-daemon gnome-console gnome-system-monitor gnome-text-editor \
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
  xdg-desktop-portal-gnome xdg-utils \
  xorg-server xorg-xkbmap xorg-xwayland \
  ccache mold ninja --noconfirm --needed

echo "=== 5. Generating fstab + addidng tmpfs ==="
genfstab -U "$MNT" >> "$MNT/etc/fstab"

# Append options for /data F2FS
echo "UUID=$(blkid -s UUID -o value ${DISK}p4) /data f2fs defaults,x-systemd.automount,nofail,compress_algorithm=lz4,compress_chksum,discard,background_gc=on 0 2" >> "$MNT/etc/fstab"

cat >> /mnt/etc/fstab <<EOF
tmpfs   /tmp    tmpfs   size=100%,mode=1777,noatime 0 0
EOF

# ------------------------
# 6) chroot and configure system
# ------------------------
echo "=== 6. Chroot and configure the system ==="
arch-chroot "$MNT" /bin/bash <<CHROOT_EOF
set -euo pipefail

# 6.1 Hostname and /etc/hosts
echo "cerebro" > /etc/hostname
cat > /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   cerebro.localdomain  cerebro
HOSTS_EOF

# 6.2 Create user and ensure home directory
useradd -m -G wheel,audio,video,network,power -s /bin/zsh "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

mkdir -p "/home/$USERNAME"
chown "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 700 "/home/$USERNAME"

# 6.3 Sudoers
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c || true

# 6.4 Initramfs
echo "Generating initramfs with mkinitcpio..."
# Minimal hooks for Intel CPU + NVIDIA GPU
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf block filesystems keyboard resume)/' /etc/mkinitcpio.conf

# Enable LZ4 compression for speed
sed -i 's/^#COMPRESSION=.*/COMPRESSION="lz4"/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-T0)/' /etc/mkinitcpio.conf

# Generate initramfs for all kernels
mkinitcpio -P


# 6.5 systemd tuning
sed -i 's/^#DefaultTimeoutStartSec=.*/DefaultTimeoutStartSec=7s/' /etc/systemd/system.conf
sed -i 's/^#DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=7s/' /etc/systemd/system.conf
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true

# 6.6 EFISTUB entry
efibootmgr -c -d /dev/nvme0n1 -p 1 -L "Cerebro LTS (EFISTUB)" \
    -l /vmlinuz-linux-lts \
    -u "root=LABEL=ROOT rw rootfstype=f2fs rootflags=compress_algorithm=lz4,compress_chksum quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 resume=LABEL=SWAP initrd=\initramfs-linux-lts.img"

# 6.7 Enable essential services
systemctl enable NetworkManager ly.service || true

echo "Chroot configuration done."
CHROOT_EOF

# ------------------------
# 7) Finalize
# ------------------------
echo "=== 7. Finalize & cleanup ==="
umount -R "$MNT" || true
swapoff -a || true

echo "Installation finished."
echo "- Please verify EFISTUB settings in firmware if needed."
echo "- Consider adding kernel cmdline options (via firmware/efibootmgr):"
echo "- quiet loglevel=3 rd.systemd.show_status=auto rd.udev.log_level=3 vt.global_cursor_default=0"
echo "Reboot when ready."

# End of script

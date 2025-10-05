#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------------
# Config (edit these)
# ------------------------
DISK="/dev/nvme0n1"         # target disk (change!)
MNT="/mnt"
USERNAME="j"                # user to create
PASSWORD="changeme"         # password (change or modify to prompt)

# Partition sizes (tweak as you like)
BOOT_SIZE="+1981M"
ROOT_SIZE="+32G"
SWAP_SIZE="+72G"
VARCACHE_SIZE="+12G"
VARLOG_SIZE="+8G"
VARLIB_SIZE="+8G"
HOME_SIZE="+22G"
BUILDS_SIZE="+24G"
# DATA = remaining

echo "=== Cerebro installer START ==="
echo "Disk: $DISK"
echo "User: $USERNAME"


# ------------------------
# 1) Partition disk
# ------------------------
echo "=== 1. Partitioning ==="
sgdisk --zap-all "$DISK"
wipefs -a "$DISK"

sgdisk -n1:0:$BOOT_SIZE -t1:EF00 -c1:"BOOT" "$DISK"
sgdisk -n2:0:$ROOT_SIZE -t2:8300 -c2:"ROOT" "$DISK"
sgdisk -n3:0:$SWAP_SIZE -t3:8200 -c3:"SWAP" "$DISK"
sgdisk -n4:0:$VARCACHE_SIZE -t4:8300 -c4:"VARCACHE" "$DISK"
sgdisk -n5:0:$VARLOG_SIZE -t5:8300 -c5:"VARLOG" "$DISK"
sgdisk -n6:0:$VARLIB_SIZE -t6:8300 -c6:"VARLIB" "$DISK"
sgdisk -n7:0:$HOME_SIZE -t7:8300 -c7:"HOME" "$DISK"
sgdisk -n8:0:$BUILDS_SIZE -t8:8300 -c8:"BUILDS" "$DISK"
sgdisk -n9:0:0 -t9:8300 -c9:"DATA" "$DISK"
sgdisk -p "$DISK"

# ------------------------
# 2) Format partitions
# ------------------------
echo "=== 2. Formatting partitions ==="
mkfs.fat -F32 "${DISK}p1" -n BOOT
mkfs.f2fs -f -l ROOT "${DISK}p2"
mkswap -L SWAP "${DISK}p3"
mkfs.f2fs -f -l VARCACHE "${DISK}p4"
mkfs.f2fs -f -l VARLOG "${DISK}p5"
mkfs.f2fs -f -l VARLIB "${DISK}p6"
mkfs.f2fs -f -l HOME "${DISK}p7"
mkfs.f2fs -f -l BUILDS "${DISK}p8"
mkfs.f2fs -f -l DATA "${DISK}p9"

# ------------------------
# 3) Mount target
# ------------------------
echo "=== 3. Mount partitions ==="
mount -t f2fs -o compress_algorithm=lz4,compress_chksum,noatime "${DISK}p2" /mnt
swapon "${DISK}p3"
mkdir -p $MNT/{boot,var/cache,var/log,var/lib,home,builds,data}
mount -t vfat -o noatime "${DISK}p1" "$MNT/boot"
mount -t f2fs -o compress_algorithm=lz4,compress_chksum,noatime "${DISK}p4" /mnt/var/cache
mount -t f2fs -o compress_algorithm=lz4,compress_chksum,noatime "${DISK}p5" /mnt/var/log
mount -t f2fs -o compress_algorithm=lz4,compress_chksum,noatime "${DISK}p6" /mnt/var/lib
mount -t f2fs -o compress_algorithm=lz4,compress_chksum,noatime "${DISK}p7" /mnt/home
mount -t f2fs -o compress_algorithm=lz4,compress_chksum,noatime "${DISK}p8" /mnt/builds
mount -t f2fs -o defaults,noatime, x-systemd.automount,nofail,compress_algorithm=lz4,compress_chksum,background_gc=on "${DISK}p9" "$MNT/data"

# ------------------------
# 4) Install base system + packages
# ------------------------
echo "=== 4. Installing base system + packages ==="
pacstrap "$MNT" \
  base base-devel \
  linux-lts linux-lts-headers \
  xfsprogs f2fs-tools \
  efibootmgr sudo nano zsh \
  intel-ucode iucode-tool nvidia-dkms nvidia-utils \
  networkmanager \
  ly \
  gnome-shell gnome-session gnome-control-center gnome-settings-daemon gnome-console gnome-system-monitor gnome-text-editor \
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber \
  xdg-desktop-portal-gnome xdg-utils \
  xorg-xwayland \
  ccache mold ninja --noconfirm --needed


# ------------------------
# 5) fstab + tmpfs
# ------------------------
echo "=== 5. Generating fstab + addidng tmpfs ==="
genfstab -U "$MNT" >> "$MNT/etc/fstab"
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

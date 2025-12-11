#!/usr/bin/env bash
set -euo pipefail
#
DISK="/dev/nvme0n1"
MNT="/mnt"
USERNAME="j"
PASSWORD="ppp" 
#
echo "==> 0. Enabling NTP"
timedatectl set-ntp true
#
echo "==> 1. Secure erase + setting the block size to 4KB"
nvme format -f --ses=2 --lbaf=1 $DISK
#
echo "==> 1.1 Disk Partitioning"
sgdisk -n1:0:+981M -t1:EF00 -c1:"BOOT" "$DISK"
sgdisk -n2:0:+40G -t2:8300 -c2:"ROOT" "$DISK"
sgdisk -n3:0:+12G -t3:8300 -c3:"PKGCACHE" "$DISK"
#
#sgdisk -n4:0:+24G -t4:8300 -c4:"STEAM" "$DISK"
#sgdisk -n5:0:+18G -t5:8300 -c5:"VIDEO" "$DISK"
#sgdisk -n6:0:0 -t6:8300 -c6:"DATA" "$DISK"
#
sgdisk -p "$DISK"
#
echo "==> 2. Formatting partitions"
mkfs.fat -F32 -n BOOT "${DISK}p1"
mkfs.f2fs -f -l ROOT -O extra_attr,inode_checksum,sb_checksum,compression "${DISK}p2"
mkfs.xfs -f -L PKGCACHE "${DISK}p3"
#
#mkfs.xfs -f -l STEAM "${DISK}p4"
#mkfs.xfs -f -L VIDEO "${DISK}p5"
#mkfs.f2fs -f -L DATA -O extra_attr,inode_checksum,sb_checksum,compression "${DISK}p6"
#
echo "==>3. Mounting Partitions"
echo "==> Mounting root"
mount -t f2fs -o defaults,noatime,nodiscard,compress_algorithm=lz4,compress_level=4,compress_chksum,fastboot /dev/nvme0n1p2 /mnt
mkdir -p /mnt/boot
echo "==> Mounting /boot"
mount -t vfat -o relatime,utf8=1 /dev/nvme0n1p1 /mnt/boot
echo "==> Mounting /pkgcache"
mount -t xfs -o relatime,allocsize=256k,discard=async /dev/nvme0n1p3 /mnt/pkgcache
#
#echo "==> Mounting /steam"
#mount -t xfs -o relatime,allocsize=1m,discard=async /dev/nvme0n1p4 /mnt/steam
#echo "==> Mounting /video"
#mount -t xfs -o relatime,allocsize=4m,discard=async /dev/nvme0n1p5 /mnt/video
#echo "==> Mounting /data"
#mount -t f2fs -o relatime,compress_algorithm=zstd,compress_chksum,discard=async /dev/nvme0n1p6 /mnt/data
#
echo "==>4. Installing base system + packages"
pacstrap /mnt base linux-lts linux-lts-headers \
intel-ucode linux-firmware-intel linux-firmware-nvidia \
mesa intel-media-driver vulkan-intel lib32-vulkan-intel \
nvidia-lts nvidia-utils lib32-nvidia-utils nv-codec-headers \
vulkan-icd-loader lib32-vulkan-icd-loader \
mesa-utils vulkan-tools base-devel efibootmgr networkmanager zsh nano git reflector \
pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber gst-plugin-pipewire rtkit \
ccache mold ninja \
gnome-shell gdm gnome-tweaks gnome-text-editor gnome-system-monitor nautilus mpv \
ttf-dejavu --noconfirm --needed
#
echo "==>5. Generating fstab"
genfstab -L /mnt >> /mnt/etc/fstab
#
echo "==>6. Chroot and configure the system ==="
arch-chroot /mnt
set -euo pipefail
#
curl -s https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/fstab > /etc/fstab
curl -s https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/makepkg.conf > /etc/makepkg.conf
curl -s https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/pacman.conf > /etc/pacman.conf
#
echo "==>6.0 Creating persistent build and cache directories"
#
# Persistent directories on /pkgcache
mkdir -p /pkgcache/paru         # Output of future AUR builds (PKGDEST)
mkdir -p /pkgcache/src          # Source tarballs / git repos
mkdir -p /pkgcache/log          # Build logs
#
# Persistent pacman cache
mkdir -p /pkgcache/pacman
#
# RAM-backed build directory
mkdir -p /rambuild
#
# Set ownership to your user
chown -R ${USERNAME}:${USERNAME} /pkgcache
chown -R ${USERNAME}:${USERNAME} /rambuild
#
# Set permissions
# all subdirs writable by owner
chmod -R 755 /pkgcache
# sticky bit, multi-user safe
chmod 1777 /rambuild
#
# Setup pacman cache symlink to persistent storage
# Ensure /var/cache exists (tmpfs created on boot)
mkdir -p /var/cache/pacman
#
# Remove default pkg folder in tmpfs (only if exists)
rm -rf /var/cache/pacman/pkg || true
#
# Create symlink to persistent XFS cache
ln -sf /pkgcache/pacman /var/cache/pacman/pkg
#
# 6.1 Timezone
ln -sf /usr/share/zoneinfo/Europe/Kiev /etc/localtime
hwclock --systohc
#
# 6.2 Locale
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
#
echo "cerebro" > /etc/hostname
useradd -m -G wheel,audio,video,storage,network,power -s /bin/zsh "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
#
mkdir -p "/home/$USERNAME"
chown "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 700 "/home/$USERNAME"
#
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c || true
#
echo "==>7. Initramfs Customization"
# HOOKS optimized for Intel + NVIDIA + F2FS + GNOME
sed -i 's/^HOOKS=.*/HOOKS=(base udev kms autodetect microcode modconf block filesystems keyboard)/' /etc/mkinitcpio.conf
# Fast initramfs compression
sed -i 's/^#COMPRESSION=.*/COMPRESSION="lz4"/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-4)/' /etc/mkinitcpio.conf
#
echo "==>8. Generate Initramfs for all kernels"
mkinitcpio -P
#
echo "==>9. Systemd tuning"
sed -i 's/^#DefaultTimeoutStartSec=.*/DefaultTimeoutStartSec=20s/' /etc/systemd/system.conf
sed -i 's/^#DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=15s/' /etc/systemd/system.conf
# Disable only the correct wait-online service for your setup
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
#
echo "==>10. Boot entry creating"
efibootmgr -c -d /dev/nvme0n1 -p 1 -L "Cerebro-LTS" -l '\vmlinuz-linux-lts' \
-u "root=LABEL=ROOT rw rootfstype=f2fs rootflags=compress_algorithm=lz4,compress_chksum quiet loglevel=3 initrd=\initramfs-linux.img"
#
systemctl enable gdm.service || true
systemctl enable NetworkManager.service || true
systemctl enable rtkit-daemon.service || true
#
echo "==>11. Chroot configuration done"
CHROOT_EOF
#
echo "==> 12. Finalize & cleanup"
umount -R /mnt || true
#
echo "Installation finished. Reboot."

#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
MNT="/mnt"
USERNAME="j"
PASSWORD="ppp" 

echo "==> 0. Enabling NTP"
timedatectl set-ntp true

echo "==> 1. Secure erase + setting the block size to 4KB"
nvme format -f --ses=2 --lbaf=1 $DISK

echo "==> 1.1 Disk Partitioning"
sgdisk -n1:0:+981M -t1:EF00 -c1:"BOOT" "$DISK"
sgdisk -n2:0:+32G -t2:8300 -c2:"ROOT" "$DISK"
sgdisk -n3:0:+16G -t3:8300 -c3:"PKGCACHE" "$DISK"
#sgdisk -n4:0:+24G -t4:8300 -c4:"STEAM" "$DISK"
#sgdisk -n5:0:+18G -t5:8300 -c5:"VIDEO" "$DISK"
#sgdisk -n6:0:0 -t6:8300 -c6:"DATA" "$DISK"
sgdisk -p "$DISK"

echo "==> 2. Formatting partitions"
mkfs.fat -F32 -n BOOT "${DISK}p1"
mkfs.f2fs -f -l ROOT -O extra_attr,inode_checksum,sb_checksum,compression "${DISK}p2"
mkfs.xfs -f -L PKGCACHE "${DISK}p3"
#mkfs.xfs -f -l STEAM "${DISK}p4"
#mkfs.xfs -f -L VIDEO "${DISK}p5"
#mkfs.f2fs -f -L DATA -O extra_attr,inode_checksum,sb_checksum,compression "${DISK}p6"

echo "==>3. Mounting Partitions"
echo "==> Mounting root"
mount -t f2fs -o relatime,compress_algorithm=lz4,compress_chksum,discard=async /dev/nvme0n1p2 /mnt
mkdir -p /mnt/{boot,pkgcache}
echo "==> Mounting /boot"
mount -t vfat -o relatime,utf8=1 /dev/nvme0n1p1 /mnt/boot
echo "==> Mounting /pkgcache"
mount -t xfs -o relatime,allocsize=256k,discard=async /dev/nvme0n1p3 /mnt/pkgcache
#echo "==> Mounting /steam"
#mount -t xfs -o relatime,allocsize=1m,discard=async /dev/nvme0n1p4 /mnt/steam
#echo "==> Mounting /video"
#mount -t xfs -o relatime,allocsize=4m,discard=async /dev/nvme0n1p5 /mnt/video
#echo "==> Mounting /data"
#mount -t f2fs -o relatime,compress_algorithm=zstd,compress_chksum,discard=async /dev/nvme0n1p6 /mnt/data


echo "==>4. Installing base system + packages"
# mesa mesa-utils mesa-vdpau libva-intel-driver intel-media-driver libva-utils
# switcheroo-control

pacstrap /mnt \
base base-devel linux-lts linux-lts-headers \
linux-firmware-intel linux-firmware-nvidia linux-firmware-realtek \
xfsprogs dosfstools f2fs-tools efibootmgr sudo nano zsh \
intel-ucode \
mesa vulkan-intel intel-media-driver libva-intel-driver xf86-video-intel \
nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
pipewire pipewire-alsa pipewire-jack pipewire-pulse wireplumber \
ly zsh\
gnome-shell networkmanager \
gst-plugin-pipewire gst-plugins-good power-profiles-daemon \
gnome-control-center gnome-tweaks \
gnome-console gnome-system-monitor gnome-text-editor nautilus mpv \
xdg-desktop-portal-gnome xdg-utils \
xorg-xwayland xorg-xinit \
ccache mold ninja --noconfirm --needed
  
echo "==>5. Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

echo "==>6. Chroot and configure the system ==="
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -euo pipefail

curl -s https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/fstab > /etc/fstab
curl -s https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/makepkg.conf > /etc/makepkg.conf
curl -s https://raw.githubusercontent.com/cerebro-tech/Cerebro/main/pacman.conf > /etc/pacman.conf

# 6.1 Timezone
ln -sf /usr/share/zoneinfo/Europe/Kiev /etc/localtime
hwclock --systohc

# 6.2 Locale
sed -i '/^#en_US.UTF-8 UTF-8/s/^#//' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf

echo "cerebro" > /etc/hostname
useradd -m -G wheel,audio,video,storage,network,power -s /bin/zsh "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

mkdir -p "/home/$USERNAME"
chown "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 700 "/home/$USERNAME"

mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
visudo -c || true

echo "==>7. Initramfs Customization"
# HOOKS optimized for Intel + NVIDIA + F2FS + GNOME/Wayland
sed -i 's/^HOOKS=.*/HOOKS=(base udev kms autodetect microcode modconf block filesystems keyboard)/' /etc/mkinitcpio.conf

# Fast initramfs compression
sed -i 's/^#COMPRESSION=.*/COMPRESSION="lz4"/' /etc/mkinitcpio.conf
sed -i 's/^#COMPRESSION_OPTIONS=.*/COMPRESSION_OPTIONS=(-4)/' /etc/mkinitcpio.conf

echo "==>8. Generate Initramfs for all kernels"
mkinitcpio -P

echo "==>9. Systemd tuning"
sed -i 's/^#DefaultTimeoutStartSec=.*/DefaultTimeoutStartSec=20s/' /etc/systemd/system.conf
sed -i 's/^#DefaultTimeoutStopSec=.*/DefaultTimeoutStopSec=15s/' /etc/systemd/system.conf
# Disable only the correct wait-online service for your setup
systemctl disable NetworkManager-wait-online.service 2>/dev/null || true


echo "==>10. Boot entry creating"
efibootmgr -c -d /dev/nvme0n1 -p 1 -L "Cerebro-LTS" -l '\vmlinuz-linux-lts' \
-u "root=LABEL=ROOT rw rootfstype=f2fs rootflags=compress_algorithm=lz4,compress_chksum quiet loglevel=3 initrd=\initramfs-linux.img"

#-u "root=LABEL=ROOT rw rootfstype=f2fs rootflags=compress_algorithm=lz4 \
#i915.enable_dpcd_backlight=1 i915.enable_psr=1 i915.enable_fbc=1 i915.enable_guc=3 \
#nvidia_drm.modeset=1 nvidia.NVreg_PreserveVideoMemoryAllocations=1 \
#intel_pstate=active intel_pstate=guided tsc=reliable random.trust_cpu=on processor.max_cstate=1 idle=nomwait rcu_nocbs=0-7 nohz=off \
#iommu=pt liburing.force_io_uring=1 nvme.pcie_gen=3 rd.systemd.show_status=false nmi_watchdog=0 nowatchdog nvme_core.default_ps_max_latency_us=0 \
#initrd=\initramfs-linux-lts.img quiet loglevel=3"

systemctl enable NetworkManager ly.service || true

echo "==>11. Chroot configuration done"
CHROOT_EOF

echo "==> 12. Finalize & cleanup"
umount -R /mnt || true

echo "Installation finished."
echo "Reboot when ready."

#!/bin/bash
set -euo pipefail

echo "🔧 Enabling NTP"
timedatectl set-ntp true

DISK="/dev/nvme0n1"
HOSTNAME="cerebro"
ROOT_PASS="777"
USER_NAME="j"
USER_PASS="777"

BOOT_SIZE="1981M"
ROOT_SIZE="44G"
HOME_SIZE="64G"
SWAP_SIZE="28G"

echo "[*] Creating partitions.."
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+${BOOT_SIZE} -t 1:ef00 -c 1:"EFI"  "$DISK"   # EFI
sgdisk -n 2:0:+${ROOT_SIZE} -t 2:8300 -c 2:"ROOT" "$DISK"   # /
sgdisk -n 3:0:+${HOME_SIZE} -t 3:8300 -c 3:"HOME" "$DISK"   # /home
sgdisk -n 4:0:+${SWAP_SIZE} -t 4:8200 -c 4:"SWAP" "$DISK"   # swap
sgdisk -n 5:0:0             -t 5:8300 -c 5:"DATA" "$DISK"   # /data (rest)

partprobe "$DISK"

echo "[*] Formatting partitions.."
mkfs.fat -F32 "${DISK}p1"

# EXT4: defaults are fast; use lazy_journal_tune + dir_index (default). Keep journaling.
mkfs.ext4 -F "${DISK}p2"
mkfs.ext4 -F "${DISK}p3"

# XFS: modern defaults already enable crc/inobt; add ftype=1 for overlayfs friendliness
mkfs.xfs -f -m crc=1,finobt=1 -n ftype=1 "${DISK}p5"

mkswap "${DISK}p4"

echo "[*] Mounting partitions.."
mount "${DISK}p2" /mnt
mkdir -p /mnt/{boot,home,data}
mount "${DISK}p1" /mnt/boot
mount "${DISK}p3" /mnt/home
mount "${DISK}p5" /mnt/data
swapon "${DISK}p4"

echo "📦 Installing base system with linux-zen"
# add linux-firmware + intel-ucode for stability/perf; efibootmgr for EFISTUB
pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware intel-ucode \
  efibootmgr sudo vim nano git zsh xfsprogs

genfstab -U /mnt >> /mnt/etc/fstab

# Tune fstab mount options for perf + safety
sed -i 's|\( / \)ext4 \(.*\)defaults\(.*\)|\1ext4 \2relatime,commit=120\3|' /mnt/etc/fstab
sed -i 's|\( /home \)ext4 \(.*\)defaults\(.*\)|\1ext4 \2relatime\3|' /mnt/etc/fstab
# /data XFS: noatime for fewer writes; use logbufs/logbsize defaults (kernel auto-tunes well on NVMe)
sed -i 's|\( /data \)xfs \(.*\)defaults\(.*\)|\1xfs \2noatime,attr2\3|' /mnt/etc/fstab

echo "🔧 Configuring system"
arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

echo "[*] Setting timezone and locale.."
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "[*] Setting hostname..."
echo "cerebro" > /etc/hostname
cat >/etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   cerebro.localdomain cerebro
H

echo "[*] Setting passwords.."
echo "root:777" | chpasswd
useradd -m -G wheel -s /bin/zsh j
echo "j:777" | chpasswd
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

echo "[*] Minimal GNOME + tools.."
# Keep essentials; remove extras later
pacman -S --needed --noconfirm \
  ly networkmanager \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  gnome-shell gnome-control-center mutter gnome-session \
  gnome-tweaks gnome-console nautilus gvfs gvfs-mtp file-roller eog evince \
  xorg-xwayland xdg-user-dirs smartmontools xfsdump extundelete timeshift

# Remove unwanted GNOME apps if pulled via deps (safe no-ops if not installed)
pacman -Rns --noconfirm \
  yelp orca gnome-tour gnome-user-share gnome-remote-desktop simple-scan \
  gnome-calendar gnome-software gnome-user-docs totem malcontent \
  gnome-weather gnome-music gnome-maps gdm epiphany || true

echo "[*] Enable services.."
systemctl enable NetworkManager
systemctl enable ly
systemctl enable fstrim.timer   # weekly TRIM for NVMe

echo "[*] mkinitcpio (add resume hook for hibernation).."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems resume)/' /etc/mkinitcpio.conf
mkinitcpio -P

echo "[*] ZRAM (LZ4) via zram-generator.."
pacman -S --noconfirm zram-generator
cat >/etc/systemd/zram-generator.conf <<Z
[zram0]
zram-size = ram/6
compression-algorithm = lz4
swap-priority = 100
Z
systemctl daemon-reload
systemctl enable systemd-zram-setup@zram0.service

echo "[*] Sysctl tuning.."
cat >/etc/sysctl.d/99-cerebro.conf <<S
vm.swappiness = 10
vm.vfs_cache_pressure = 50
S

echo "[*] Kernel cmdline (EFISTUB) with zswap + hibernate.."
ROOT_UUID=\$(blkid -s UUID -o value ${DISK}p2)
SWAP_UUID=\$(blkid -s UUID -o value ${DISK}p4)

# EFISTUB expects kernel+initramfs on ESP root (/boot is the ESP)
# Paths are UEFI-style: backslashes, absolute from ESP root.
efibootmgr -c -d ${DISK} -p 1 \
  -L "Arch Linux (Zen, EFISTUB)" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\intel-ucode.img initrd=\initramfs-linux-zen.img root=UUID=\$ROOT_UUID rw \
quiet loglevel=3 nowatchdog \
zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=20 zswap.zpool=z3fold \
resume=UUID=\$SWAP_UUID"

echo "[*] Create /data subdirs.."
mkdir -p /data/{projects,video,datasets}
chown -R j:j /data

EOF

echo "[*] Cerebro installation complete. Rebooting .."
umount -R /mnt
swapoff "${DISK}p4" || true
reboot

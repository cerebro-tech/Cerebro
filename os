#!/bin/bash
# Cerebro OS Arch Installer (Intel, EFISTUB, Booster, ZRAM, Preload)
# Steps and comments included for future modifications

set -e

# Step 1: Detect disks >= 32G
echo "Detecting available disks..."
AVAILABLE_DISKS=()
for disk in /dev/sd? /dev/nvme?n?; do
    if [ -b "$disk" ]; then
        SIZE_GB=$(lsblk -bno SIZE "$disk")
        SIZE_GB=$((SIZE_GB / 1024 / 1024 / 1024))
        if [ $SIZE_GB -ge 32 ]; then
            AVAILABLE_DISKS+=("$disk ($SIZE_GB GB)")
        fi
    fi
done

echo "Available disks for installation:"
for i in "${!AVAILABLE_DISKS[@]}"; do
    echo "[$i] ${AVAILABLE_DISKS[$i]}"
done

read -rp "Choose disk [0-${#AVAILABLE_DISKS[@]}]: " DISK_IDX
DISK_PATH=$(echo "${AVAILABLE_DISKS[$DISK_IDX]}" | cut -d' ' -f1)

# Step 2: Ask user if they want /data
read -rp "Create /data partition? Enter size in GB (0 = skip, max remaining = -1): " DATA_SIZE

# Step 3: Confirm wipe if disk has data
if blkid "$DISK_PATH" >/dev/null 2>&1; then
    read -rp "$DISK_PATH contains data. Clean it? [y/N]: " CLEAN_DISK
    if [[ $CLEAN_DISK =~ ^[Yy]$ ]]; then
        if [[ "$DISK_PATH" == /dev/nvme* ]]; then
            nvme format -f "$DISK_PATH"
        else
            wipefs -af "$DISK_PATH"
        fi
    fi
fi

# Step 4: Partitioning (EFI, swap, /, /home, optional /data)
# Minimum sizes
MIN_ROOT=20
MIN_HOME=10
MIN_SWAP=4

echo "Partitioning $DISK_PATH..."
sgdisk -Z "$DISK_PATH" # zap all

# EFI
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI"
# Swap
sgdisk -n 2:0:+${MIN_SWAP}G -t 2:8200 -c 2:"SWAP"
# Root
sgdisk -n 3:0:+${MIN_ROOT}G -t 3:8300 -c 3:"ROOT"
# Home
sgdisk -n 4:0:+${MIN_HOME}G -t 4:8300 -c 4:"HOME"

# Optional /data
if [ "$DATA_SIZE" -gt 0 ]; then
    if [ "$DATA_SIZE" -eq -1 ]; then
        sgdisk -n 5:0:0 -t 5:8300 -c 5:"DATA"
    else
        sgdisk -n 5:0:+${DATA_SIZE}G -t 5:8300 -c 5:"DATA"
    fi
fi

partprobe "$DISK_PATH"

# Step 5: Format partitions
mkfs.fat -F32 "${DISK_PATH}1"
mkswap "${DISK_PATH}2"
swapon "${DISK_PATH}2"
mkfs.ext4 -F "${DISK_PATH}3"
mkfs.ext4 -F "${DISK_PATH}4"
if [ "$DATA_SIZE" -gt 0 ]; then
    mkfs.xfs -f "${DISK_PATH}5"
fi

# Step 6: Mount partitions
mount "${DISK_PATH}3" /mnt
mkdir -p /mnt/{boot,home}
mount "${DISK_PATH}1" /mnt/boot
mount "${DISK_PATH}4" /mnt/home
if [ "$DATA_SIZE" -gt 0 ]; then
    mkdir -p /mnt/data
    mount "${DISK_PATH}5" /mnt/data
fi

# Step 7: Enable ZRAM
modprobe zram
echo lz4 > /sys/block/zram0/comp_algorithm
echo 16G > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0

# Step 8: Configure pacman
echo "[multilib]
Include = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf

# Add Chaotic AUR
pacman-key --recv-key 3056513887B78AEB --keyserver keyserver.ubuntu.com
pacman-key --lsign-key 3056513887B78AEB
echo -e "[chaotic-aur]\nSigLevel = Never\nServer = https://lonewolf-builder.duckdns.org/chaotic-aur/x86_64" >> /etc/pacman.conf

# Step 9: Install base system + packages
pacstrap -K /mnt base base-devel linux-zen linux-firmware intel-ucode \
  networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr \
  xorg-server xorg-xinit xorg-xwayland \
  gnome-shell gnome-session gnome-control-center gnome-terminal gnome-text-editor \
  nautilus eog evince file-roller gnome-keyring gnome-backgrounds \
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
  xdg-user-dirs xdg-utils \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  ly preload pigz booster mold ninja

# Step 10: Chroot & configure
arch-chroot /mnt /bin/bash <<'EOF'

# Step 10a: Enable NetworkManager
systemctl enable NetworkManager

# Step 10b: Configure hostname & passwords
echo "cerebro" > /etc/hostname
echo "j:777" | chpasswd
echo "root:777" | chpasswd

# Step 10c: Rust & makepkg optimizations
cat > /etc/makepkg.conf.d/rust.conf <<'RUST'
#!/hint/bash
# shellcheck disable=2034
RUSTFLAGS="-C target-cpu=native -C opt-level=3 -C link-arg=-fuse-ld=mold -C strip=symbols"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUST

sed -i 's/^#CFLAGS.*/CFLAGS="-march=native -O3"/' /etc/makepkg.conf
sed -i 's/^#LDFLAGS.*/LDFLAGS="-flto"/' /etc/makepkg.conf
sed -i 's/^#MAKEFLAGS.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
sed -i 's/^#COMPRESSZST.*/COMPRESSZST=(zstd -c -T0 --auto-threads=logical)/' /etc/makepkg.conf
sed -i 's/^#COMPRESSLZ4.*/COMPRESSLZ4=(lz4 -q --no-frame-crc)/' /etc/makepkg.conf
sed -i 's/^#COMPRESSGZ.*/COMPRESSGZ=(pigz -c -f -n)/' /etc/makepkg.conf
sed -i 's/^#PKGEXT.*/PKGEXT=".pkg.tar.lz4"/' /etc/makepkg.conf

# Step 10d: Install paru from Git
git clone https://aur.archlinux.org/paru.git /tmp/paru
cd /tmp/paru
makepkg -si --noconfirm

# Step 10e: EFISTUB boot entries
ROOT_UUID=$(blkid -s UUID -o value /dev/sd3)
SWAP_UUID=$(blkid -s UUID -o value /dev/sd2)
efibootmgr -c -d /dev/sdX -p 1 -L "Arch Linux (Zen, EFISTUB)" -l '\vmlinuz-linux-zen' -u "initrd=\initramfs-linux-zen.img root=UUID=$ROOT_UUID rw quiet resume=UUID=$SWAP_UUID"
efibootmgr -c -d /dev/sdX -p 1 -L "Arch Linux (Zen+Booster, EFISTUB)" -l '\vmlinuz-linux-zen' -u "initrd=\booster-linux-zen.img root=UUID=$ROOT_UUID rw quiet resume=UUID=$SWAP_UUID"

EOF

echo "Installation complete! Reboot and remove installation media."

#!/bin/bash
# Cerebro OS Installer Script (Final Performance Version)
# For Arch Linux installation on Intel-based laptops
# ---------------------------------------------------
# Step 0: Verify running as root
if [ "$EUID" -ne 0 ]; then
    echo "Run this script as root!"
    exit 1
fi

# Step 1: Detect available disks (≥32G)
echo "Detecting available disks..."
DISKS=($(lsblk -dno NAME,SIZE | awk '$2+0>=32 {print $1}'))
if [ ${#DISKS[@]} -eq 0 ]; then
    echo "No suitable disks found (>=32GB)"
    exit 1
fi

echo "Available disks for installation:"
for i in "${!DISKS[@]}"; do
    echo "[$i] ${DISKS[$i]}"
done
read -rp "Choose disk index to install: " DISK_IDX
DISK="/dev/${DISKS[$DISK_IDX]}"

# Step 2: Confirm cleaning disk if it contains data
if lsblk "$DISK" | grep -q part; then
    read -rp "Disk $DISK has partitions, clean it? (y/N): " CLEAN
    if [[ "$CLEAN" =~ ^[Yy]$ ]]; then
        echo "Cleaning disk $DISK..."
        if [[ "$DISK" == /dev/nvme* ]]; then
            nvme format -f "$DISK"
        fi
        sgdisk --zap-all "$DISK"
    fi
fi

# Step 3: Partitioning
BOOT_SIZE=1     # GB
ROOT_SIZE=20    # GB
HOME_SIZE=10    # GB
read -rp "Enter /data partition size in GB (0 to skip, max for remaining): " DATA_SIZE

# Create partitions
sgdisk -n 1:0:+${BOOT_SIZE}G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:+${ROOT_SIZE}G -t 2:8300 -c 2:"ROOT" "$DISK"
sgdisk -n 3:0:+${HOME_SIZE}G -t 3:8300 -c 3:"HOME" "$DISK"

if [ "$DATA_SIZE" -gt 0 ]; then
    sgdisk -n 4:0:+${DATA_SIZE}G -t 4:8300 -c 4:"DATA" "$DISK"
fi

# Swap (16GB)
sgdisk -n 5:0:+16G -t 5:8200 -c 5:"SWAP" "$DISK"

# Step 4: Formatting
mkfs.fat -F32 "${DISK}1"
mkfs.ext4 -F "${DISK}2"
mkfs.ext4 -F "${DISK}3"
if [ "$DATA_SIZE" -gt 0 ]; then
    mkfs.xfs -f "${DISK}4"
fi
mkswap "${DISK}5"
swapon "${DISK}5"

# Step 5: Mount
mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot
mkdir -p /mnt/home
mount "${DISK}3" /mnt/home
if [ "$DATA_SIZE" -gt 0 ]; then
    mkdir -p /mnt/data
    mount "${DISK}4" /mnt/data
fi

# Step 6: Pacstrap (Base + GNOME + Ly + PipeWire + Utilities)
pacstrap -K /mnt base base-devel linux-zen linux-firmware intel-ucode \
    networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr \
    xorg-server xorg-xinit xorg-xwayland \
    gnome-shell gnome-session gnome-control-center gnome-terminal gnome-text-editor \
    nautilus eog evince file-roller gnome-keyring gnome-backgrounds \
    gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
    xdg-user-dirs xdg-utils \
    pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
    ly preload

# Step 7: Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Step 8: Chroot & Configure
arch-chroot /mnt /bin/bash <<'EOF'
# Step 8a: Set hostname & users
echo "cerebro" > /etc/hostname
echo "root:777" | chpasswd
useradd -m -G wheel j
echo "j:777" | chpasswd

# Step 8b: Install packages for performance & builders
pacman -Sy --noconfirm pigz booster mold ninja git base-devel
# Booster auto-creates /boot/booster-linux-zen.img

# Step 8c: Install paru
cd /opt
git clone https://aur.archlinux.org/paru.git
chown -R root:root paru
cd paru
makepkg -si --noconfirm

# Step 8d: Configure Rust
cat <<RUSTCONF > /etc/makepkg.conf.d/rust.conf
#!/hint/bash
# shellcheck disable=2034
RUSTFLAGS="-C target-cpu=native -C opt-level=3 -C link-arg=-fuse-ld=mold -C strip=symbols"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUSTCONF

# Step 8e: Modify makepkg.conf
sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
cat <<MAKEPKG >> /etc/makepkg.conf
CFLAGS="-march=native -O3"
LTOFLAGS="-flto"
export NINJAFLAGS="-j\$(nproc)"
OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
COMPRESSZST=(zstd -c -T0 --auto-threads=logical)
COMPRESSLZ4=(lz4 -q --no-frame-crc)
COMPRESSGZ=(pigz -c -f -n)
PKGEXT='.pkg.tar.lz4'
MAKEPKG

# Step 8f: Setup EFISTUB boots
ROOT_UUID=$(blkid -s UUID -o value $(lsblk -no NAME,TYPE | grep part | grep ROOT | awk '{print "/dev/"$1}'))
SWAP_UUID=$(blkid -s UUID -o value $(lsblk -no NAME,TYPE | grep part | grep SWAP | awk '{print "/dev/"$1}'))

efibootmgr -c -d $DISK -p 1 -L "Arch Linux (Zen, EFISTUB)" \
    -l '\vmlinuz-linux-zen' \
    -u "initrd=\initramfs-linux-zen.img root=UUID=$ROOT_UUID rw resume=UUID=$SWAP_UUID quiet loglevel=3"

efibootmgr -c -d $DISK -p 1 -L "Arch Linux (Zen + Booster)" \
    -l '\vmlinuz-linux-zen' \
    -u "initrd=\booster-linux-zen.img root=UUID=$ROOT_UUID rw resume=UUID=$SWAP_UUID quiet loglevel=3"

# Step 8g: Enable services
systemctl enable NetworkManager
systemctl enable ly

# Step 8h: Setup ZRAM (default 2GB)
echo "zram0" > /etc/modules-load.d/zram.conf
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = 2G
compression-algorithm = zstd
ZRAM
EOF

echo "Installation completed! Reboot system."

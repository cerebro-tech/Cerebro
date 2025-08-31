#!/usr/bin/env bash
set -euo pipefail

echo "=== Cerebro Arch Installer (EFISTUB, Zen, GNOME+Ly) ==="

# -----------------------------
# Minimum sizes (in MB)
# -----------------------------
MIN_BOOT=512          # /boot (FAT32)
MIN_ROOT=20480        # / (ext4)
MIN_HOME=10240        # /home (ext4)
MIN_SWAP=2048         # swap (for hibernation you’ll want > RAM/2; you chose 28G earlier)
MIN_DATA=1024         # /data (XFS) optional

# -----------------------------
# pick target disk
# -----------------------------
echo
echo "[*] Available disks:"
lsblk -d -o NAME,SIZE,MODEL | awk '{printf "  %s  %s  %s\n",$1,$2,substr($0,index($0,$3))}'
echo
read -rp "Enter disk (e.g., nvme0n1 or sda): " DISK_NAME
DISK="/dev/${DISK_NAME}"

if [[ ! -b "$DISK" ]]; then
  echo "❌ $DISK is not a block device"; exit 1
fi

echo "⚠️  This will install Arch to $DISK."
read -rp "Type YES to continue: " OK; [[ "$OK" == "YES" ]] || { echo "Aborted."; exit 1; }

# -----------------------------
# check & wipe only if not clean
# -----------------------------
echo "[*] Checking if $DISK is clean..."
HAS_PARTS=$(lsblk -nrpo NAME "$DISK" | tail -n +2 | wc -l)
if (( HAS_PARTS > 0 )) || wipefs -n "$DISK" | grep -q . ; then
  echo "[!] Existing partitions or signatures detected on $DISK — wiping..."
  sgdisk --zap-all "$DISK"
  wipefs -a "$DISK" || true
  partprobe "$DISK" || true
  echo "[*] Wipe done."
else
  echo "[*] Disk appears clean. Proceeding."
fi

# -----------------------------
# input sizes
# -----------------------------
to_mb() { # accept GB integer -> MB
  local gb="$1"; echo $(( gb * 1024 ))
}

ask_size_gb() {
  local label="$1" default_gb="$2" min_mb="$3" out
  while true; do
    read -rp "Enter ${label} size in GB [default ${default_gb}]: " out
    out="${out:-$default_gb}"
    if ! [[ "$out" =~ ^[0-9]+$ ]]; then
      echo "  -> enter integer GB"
      continue
    fi
    local mb; mb=$(to_mb "$out")
    if (( mb < min_mb )); then
      echo "  -> too small; minimum is $((min_mb/1024)) GB"
      continue
    fi
    echo "$out"; return 0
  done
}

# sensible defaults per your earlier plan
BOOT_MB=$MIN_BOOT
ROOT_GB=$(ask_size_gb "/"     44   $MIN_ROOT)
HOME_GB=$(ask_size_gb "/home" 64   $MIN_HOME)
SWAP_GB=$(ask_size_gb "swap"  28   $MIN_SWAP)

# /data: 0 = skip, N = size in GB, 'max' = remaining
while true; do
  read -rp "Enter /data size (GB). Use 0 to skip or 'max' for remaining: " DATA_IN
  DATA_IN=${DATA_IN,,}
  if [[ "$DATA_IN" == "0" || "$DATA_IN" == "max" || "$DATA_IN" =~ ^[0-9]+$ ]]; then
    break
  fi
  echo "  -> enter 0, a number (GB), or 'max'"
done

# -----------------------------
# compute 'max' for /data
# -----------------------------
TOTAL_MB=$(lsblk -bno SIZE "$DISK" | awk '{print int($1/1024/1024)}')
ROOT_MB=$(to_mb "$ROOT_GB")
HOME_MB=$(to_mb "$HOME_GB")
SWAP_MB=$(to_mb "$SWAP_GB")

# GPT uses a bit of space; leave ~16MB safety
RESERVED_MB=16
USED_MB=$(( BOOT_MB + ROOT_MB + SWAP_MB + HOME_MB + RESERVED_MB ))
REMAIN_MB=$(( TOTAL_MB - USED_MB ))
if (( REMAIN_MB < 0 )); then
  echo "❌ Requested sizes exceed disk capacity. Reduce sizes."; exit 1
fi

CREATE_DATA=false
if [[ "$DATA_IN" == "0" ]]; then
  CREATE_DATA=false
elif [[ "$DATA_IN" == "max" ]]; then
  if (( REMAIN_MB >= MIN_DATA )); then
    DATA_MB=$REMAIN_MB; CREATE_DATA=true
  else
    echo "[!] Not enough remaining space for /data (min ${MIN_DATA}MB). Skipping /data."
    CREATE_DATA=false
  fi
else
  DATA_MB=$(to_mb "$DATA_IN")
  if (( DATA_MB < MIN_DATA )); then
    echo "❌ /data must be at least $((MIN_DATA/1024)) GB"; exit 1
  fi
  if (( DATA_MB > REMAIN_MB )); then
    echo "❌ /data too large; only $((REMAIN_MB/1024)) GB free remains"; exit 1
  fi
  CREATE_DATA=true
fi

# -----------------------------
# create partitions (sgdisk)
# order: ESP, ROOT, SWAP, HOME, DATA?
# -----------------------------
echo "[*] Creating partitions on $DISK..."
sgdisk -n 1:0:+${BOOT_MB}M     -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:+${ROOT_MB}M     -t 2:8300 -c 2:"ROOT" "$DISK"
sgdisk -n 3:0:+${SWAP_MB}M     -t 3:8200 -c 3:"SWAP" "$DISK"
sgdisk -n 4:0:+${HOME_MB}M     -t 4:8300 -c 4:"HOME" "$DISK"
if $CREATE_DATA; then
  sgdisk -n 5:0:+${DATA_MB}M   -t 5:8300 -c 5:"DATA" "$DISK"
fi
partprobe "$DISK"; sleep 2

# NVMe partitions need 'p' suffix
if [[ "$DISK_NAME" == nvme* ]]; then
  ESP="${DISK}p1"; ROOT="${DISK}p2"; SWAP="${DISK}p3"; HOME_PART="${DISK}p4"; DATA="${DISK}p5"
else
  ESP="${DISK}1";  ROOT="${DISK}2";  SWAP="${DISK}3"; HOME_PART="${DISK}4"; DATA="${DISK}5"
fi

# -----------------------------
# make filesystems
# -----------------------------
echo "[*] Formatting filesystems..."
mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"
mkfs.ext4 -F "$HOME_PART"
mkswap "$SWAP"
if $CREATE_DATA; then
  mkfs.xfs -f -m crc=1,finobt=1 -n ftype=1 "$DATA"
fi

# -----------------------------
# mount
# -----------------------------
echo "[*] Mounting..."
mount "$ROOT" /mnt
mkdir -p /mnt/{boot,home}
mount "$ESP" /mnt/boot
mount "$HOME_PART" /mnt/home
if $CREATE_DATA; then
  mkdir -p /mnt/data
  mount "$DATA" /mnt/data
fi
swapon "$SWAP"

# -----------------------------
# base install
# -----------------------------
echo "[*] Installing base system..."
pacstrap -K /mnt base base-devel linux-zen linux-firmware intel-ucode \
  networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr \
  xorg-server xorg-xinit xorg-xwayland \
  gnome-shell gnome-session gnome-control-center gnome-terminal gnome-text-editor \
  nautilus eog evince file-roller gnome-keyring gnome-backgrounds \
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
  xdg-user-dirs xdg-utils \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  ly

genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# chroot configure
# -----------------------------
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# timezone & locale
ln -sf /usr/share/zoneinfo/Europe/Kyiv /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# hostname & hosts
echo "cerebro" > /etc/hostname
cat >/etc/hosts <<H
127.0.0.1   localhost
::1         localhost
127.0.1.1   cerebro.localdomain cerebro
H

# users
echo "root:777" | chpasswd
useradd -m -G wheel -s /bin/zsh j
echo "j:777" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99_wheel

# start services
systemctl enable NetworkManager
systemctl enable ly

# ensure X starts GNOME from Ly (startx)
echo 'exec dbus-run-session gnome-session' > /home/j/.xinitrc
chown j:j /home/j/.xinitrc

# mkinitcpio: add resume for hibernation
if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems resume fsck)/' /etc/mkinitcpio.conf
fi
mkinitcpio -P

# EFISTUB entry (kernel/initramfs live on ESP because /boot is ESP)
ROOT_UUID=\$(blkid -s UUID -o value "$ROOT")
SWAP_UUID=\$(blkid -s UUID -o value "$SWAP")

efibootmgr -c -d "$DISK" -p 1 \
  -L "Arch Linux (Zen, EFISTUB)" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\\intel-ucode.img initrd=\\initramfs-linux-zen.img root=UUID=\$ROOT_UUID rw quiet resume=UUID=\$SWAP_UUID"
EOF

echo
echo "✅ Install complete."
echo "   Disk: $DISK"
echo "   /boot(FAT32)=$ESP  / (ext4)=$ROOT  /home (ext4)=$HOME_PART  swap=$SWAP  /data(XFS)=${CREATE_DATA:+$DATA}"
echo "→ Reboot when ready."

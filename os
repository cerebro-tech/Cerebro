#!/usr/bin/env bash
# Final general-purpose Cerebro Arch installer (EFISTUB, Zen, Booster, ZRAM, Ly, preload, performant makepkg)
# Run from the Arch ISO as root. This WILL wipe the selected disk when you confirm.

set -euo pipefail
shopt -s nullglob

# -----------------------------
# Step 0: quick checks
# -----------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Run as root (from the Arch ISO)." >&2
  exit 1
fi

timedatectl set-ntp true

# -----------------------------
# Step 1: detect CPU & GPU (host/live env)
# -----------------------------
CPU_VENDOR=$(lscpu 2>/dev/null | awk -F: '/Vendor ID/ {print $2}' | xargs || true)
GPU_INFO=$(lspci 2>/dev/null | grep -E "VGA|3D" | head -n1 || true)
GPU_VENDOR=""
if [[ $GPU_INFO =~ [Nn]VIDIA ]]; then GPU_VENDOR="nvidia"; fi
if [[ $GPU_INFO =~ [Aa][Mm][Dd] ]]; then GPU_VENDOR="amd"; fi
if [[ $GPU_INFO =~ [Ii]ntel ]]; then GPU_VENDOR="intel"; fi

MICROCODE_PKG=""
[[ "$CPU_VENDOR" == "GenuineIntel" ]] && MICROCODE_PKG="intel-ucode"
[[ "$CPU_VENDOR" == "AuthenticAMD" ]] && MICROCODE_PKG="amd-ucode"

echo "[STEP 1] CPU vendor: ${CPU_VENDOR:-unknown}, GPU vendor: ${GPU_VENDOR:-unknown}"
echo "[STEP 1] microcode package chosen: ${MICROCODE_PKG:-none}"

# -----------------------------
# Step 2: disk detection (>=32 GiB)
# -----------------------------
echo "[STEP 2] detecting disks >= 32 GiB..."
mapfile -t CANDIDATE_DISKS < <(lsblk -dno NAME,SIZE | awk '$2+0 >= 34359738368 {print "/dev/"$1}')
if [[ ${#CANDIDATE_DISKS[@]} -eq 0 ]]; then
  echo "No disks >=32GB found. Exiting." >&2
  exit 1
fi

if [[ ${#CANDIDATE_DISKS[@]} -eq 1 ]]; then
  DISK="${CANDIDATE_DISKS[0]}"
  echo "[STEP 2] single disk found; auto-selected: $DISK"
else
  echo "Available disks:"
  for i in "${!CANDIDATE_DISKS[@]}"; do
    printf "  [%d] %s\n" $((i+1)) "${CANDIDATE_DISKS[$i]}"
  done
  while true; do
    read -rp "Choose disk number to install to: " disk_choice
    if [[ "$disk_choice" =~ ^[0-9]+$ ]] && (( disk_choice >= 1 && disk_choice <= ${#CANDIDATE_DISKS[@]} )); then
      DISK="${CANDIDATE_DISKS[$((disk_choice-1))]}"
      break
    fi
    echo "Invalid choice."
  done
fi

echo "[STEP 2] target disk: $DISK"
read -rp "This will erase $DISK — type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted by user."; exit 1; }

# -----------------------------
# Step 3: wipe disk signatures (fast)
# -----------------------------
echo "[STEP 3] wiping partition table & signatures (fast)..."
sgdisk --zap-all "$DISK" || true
wipefs -a "$DISK" || true
partprobe "$DISK" || true

# NVMe special formatting (ask)
if [[ "$DISK" == /dev/nvme* ]] && command -v nvme >/dev/null 2>&1; then
  read -rp "NVMe device detected. Run nvme format -f (secure fast) on $DISK? (y/N): " nvme_confirm
  if [[ "$nvme_confirm" =~ ^[Yy]$ ]]; then
    echo "[STEP 3] nvme format -f $DISK (may take seconds)..."
    nvme format -f "$DISK" || echo "nvme format failed (continuing)."
    # wipefs again
    wipefs -a "$DISK" || true
    partprobe "$DISK" || true
  fi
fi

# -----------------------------
# Step 4: ask partition sizes (boot in MB, others in GB)
# -----------------------------
echo "[STEP 4] partition sizes (boot in MB, others in GB). Min checks applied."

read -rp "Enter /boot size in MB [default 1981]: " BOOT_MB
BOOT_MB=${BOOT_MB:-1981}
(( BOOT_MB >= 512 )) || { echo "boot must be >= 512 MB"; exit 1; }

read -rp "Enter / (root) size in GB [default 44]: " ROOT_GB
ROOT_GB=${ROOT_GB:-44}
(( ROOT_GB >= 20 )) || { echo "/ root must be >= 20 GB"; exit 1; }

read -rp "Enter /home size in GB [default 64]: " HOME_GB
HOME_GB=${HOME_GB:-64}
(( HOME_GB >= 10 )) || { echo "/home must be >= 10 GB"; exit 1; }

read -rp "Enter swap size in GB [default 28]: " SWAP_GB
SWAP_GB=${SWAP_GB:-28}
(( SWAP_GB >= 1 )) || { echo "swap must be >= 1 GB"; exit 1; }

# /data: 0 skip, integer GB, or 'max'
read -rp "Enter /data size in GB (0=skip, max=use remaining) [default 0]: " DATA_IN
DATA_IN=${DATA_IN:-0}

# Convert GB to MB for sgdisk
ROOT_MB=$(( ROOT_GB * 1024 ))
HOME_MB=$(( HOME_GB * 1024 ))
SWAP_MB=$(( SWAP_GB * 1024 ))

# Before creating a /data size, compute remaining space if needed
TOTAL_DISK_MB=$(lsblk -bno SIZE "$DISK")
TOTAL_DISK_MB=$(( TOTAL_DISK_MB / 1024 / 1024 ))
RESERVED_MB=16
USED_MB=$(( BOOT_MB + ROOT_MB + HOME_MB + SWAP_MB + RESERVED_MB ))
REMAIN_MB=$(( TOTAL_DISK_MB - USED_MB ))
if (( REMAIN_MB < 0 )); then
  echo "Requested sizes exceed disk capacity. Reduce sizes." >&2
  exit 1
fi

if [[ "$DATA_IN" == "max" ]]; then
  if (( REMAIN_MB < 1024 )); then
    echo "Not enough free space for /data; skipping /data."
    CREATE_DATA=false
  else
    DATA_MB=$REMAIN_MB
    CREATE_DATA=true
  fi
elif [[ "$DATA_IN" =~ ^[0-9]+$ ]] && (( DATA_IN > 0 )); then
  DATA_MB=$(( DATA_IN * 1024 ))
  if (( DATA_MB > REMAIN_MB )); then
    echo "/data size too large for remaining disk space ($REMAIN_MB MiB). Aborting." >&2
    exit 1
  fi
  CREATE_DATA=true
else
  CREATE_DATA=false
fi

echo "[STEP 4] Partition plan (MiB): boot=${BOOT_MB} root=${ROOT_MB} home=${HOME_MB} swap=${SWAP_MB} data=${CREATE_DATA:+$DATA_MB (MiB)}"

# -----------------------------
# Step 5: create partitions with sgdisk (MB units)
# -----------------------------
echo "[STEP 5] creating partitions..."
sgdisk --zap-all "$DISK" >/dev/null 2>&1 || true

# create partitions: ESP, ROOT, HOME, SWAP, DATA (optional)
sgdisk -n 1:0:+${BOOT_MB}M -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:+${ROOT_MB}M -t 2:8300 -c 2:"ROOT" "$DISK"
sgdisk -n 3:0:+${HOME_MB}M -t 3:8300 -c 3:"HOME" "$DISK"
sgdisk -n 4:0:+${SWAP_MB}M -t 4:8200 -c 4:"SWAP" "$DISK"
if $CREATE_DATA; then
  # if DATA_IN == max we already set DATA_MB accordingly
  if [[ "$DATA_IN" == "max" ]]; then
    sgdisk -n 5:0:0 -t 5:8300 -c 5:"DATA" "$DISK"
  else
    sgdisk -n 5:0:+${DATA_MB}M -t 5:8300 -c 5:"DATA" "$DISK"
  fi
fi

partprobe "$DISK"
sleep 1

# determine partition device names (nvme vs sd)
if [[ "$DISK" == *"nvme"* ]]; then
  ESP="${DISK}p1"
  ROOT="${DISK}p2"
  HOME="${DISK}p3"
  SWAP="${DISK}p4"
  DATA="${DISK}p5"
else
  ESP="${DISK}1"
  ROOT="${DISK}2"
  HOME="${DISK}3"
  SWAP="${DISK}4"
  DATA="${DISK}5"
fi

# -----------------------------
# Step 6: format partitions (ext4 for / and /home; xfs for /data)
# -----------------------------
echo "[STEP 6] Formatting partitions..."
mkfs.fat -F32 "$ESP"
mkfs.ext4 -F "$ROOT"
mkfs.ext4 -F "$HOME"
mkswap "$SWAP"
if $CREATE_DATA; then
  mkfs.xfs -f -m crc=1,finobt=1 -n ftype=1 "$DATA"
fi

# -----------------------------
# Step 7: mount
# -----------------------------
echo "[STEP 7] Mounting..."
mount "$ROOT" /mnt
mkdir -p /mnt/{boot,home}
mount "$ESP" /mnt/boot
mount "$HOME" /mnt/home
swapon "$SWAP"
if $CREATE_DATA; then
  mkdir -p /mnt/data
  mount "$DATA" /mnt/data
fi

# -----------------------------
# Step 8: pacstrap (install base system + tools)
# -----------------------------
echo "[STEP 8] Installing base system (this may take a while)..."

# Build list of device-specific packages
DRIVER_PKGS=""
if [[ "$GPU_VENDOR" == "nvidia" ]]; then
  DRIVER_PKGS+=" nvidia nvidia-utils"
elif [[ "$GPU_VENDOR" == "amd" ]]; then
  DRIVER_PKGS+=" xf86-video-amdgpu mesa"
elif [[ "$GPU_VENDOR" == "intel" ]]; then
  DRIVER_PKGS+=" mesa"
fi

# core pacstrap list (DO NOT include preload here; it's in Chaotic repo; will be installed in chroot)
pacstrap -K /mnt base base-devel linux-zen linux-firmware ${MICROCODE_PKG} \
  networkmanager sudo zsh xfsprogs e2fsprogs efibootmgr \
  xorg-server xorg-xinit xorg-xwayland \
  gnome-shell gnome-session gnome-control-center gnome-terminal gnome-text-editor \
  nautilus eog evince file-roller gnome-keyring gnome-backgrounds \
  gvfs gvfs-mtp gvfs-smb gvfs-nfs gvfs-afc \
  xdg-user-dirs xdg-utils \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  ly pigz mold ninja git ${DRIVER_PKGS}

# -----------------------------
# Step 9: fstab
# -----------------------------
genfstab -U /mnt >> /mnt/etc/fstab

# -----------------------------
# Prepare zram size based on RAM (half RAM, capped)
# -----------------------------
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_MB=$(( MEM_KB / 1024 ))
# choose zram size as min( mem/2, 16384 )
ZRAM_MB=$(( MEM_MB / 2 ))
(( ZRAM_MB > 16384 )) && ZRAM_MB=16384
echo "[STEP 9] RAM ${MEM_MB} MiB → configuring ZRAM ${ZRAM_MB} MiB"

# write zram config into targetfs (will be used by zram-generator)
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ${ZRAM_MB}M
compression-algorithm = lz4
EOF

# -----------------------------
# Step 10: chroot - configure system
# -----------------------------
echo "[STEP 10] Entering chroot to finish configuration..."
# capture values for expansion into heredoc
export HOSTNAME="cerebro"
export ROOT_PART="$ROOT"
export SWAP_PART="$SWAP"
export DISK_DEVICE="$DISK"
export TZ_NAME="$(curl -s https://ipapi.co/timezone || echo "UTC")"
export CREATE_DATA

arch-chroot /mnt /bin/bash <<'CHROOT_EOF'
set -euo pipefail

# --- Step 10.1 Timezone & locale ---
ln -sf /usr/share/zoneinfo/"${TZ_NAME}" /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# --- Step 10.2 Hostname & hosts ---
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

# --- Step 10.3 users & sudo ---
echo "root:777" | chpasswd
useradd -m -G wheel -s /bin/zsh j || true
echo "j:777" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/99_wheel
chmod 0440 /etc/sudoers.d/99_wheel

# --- Step 10.4 mkinitcpio (ensure resume hook) ---
if grep -q '^HOOKS=' /etc/mkinitcpio.conf; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf block filesystems resume fsck)/' /etc/mkinitcpio.conf
else
  echo 'HOOKS=(base udev autodetect modconf block filesystems resume fsck)' >> /etc/mkinitcpio.conf
fi
mkinitcpio -P

# --- Step 10.5 enable services we need ---
systemctl enable NetworkManager
systemctl enable ly
systemctl enable fstrim.timer || true

# --- Step 10.6 enable zram-generator if present (package should be in target) ---
if pacman -Qi zram-generator &>/dev/null; then
  systemctl enable systemd-zram-setup@zram0.service || true
fi

# --- Step 10.7 enable other tuneups (optional) ---
# nothing else here

# --- Step 10.8 add multilib repository (uncomment) and refresh pacman ---
sed -i '/#\\[multilib\\]/,/Include/ s/^#//' /etc/pacman.conf || true
pacman -Sy --noconfirm

# --- Step 10.9 Chaotic-AUR (for preload) - install keyring and mirrorlist then repo ---
cd /tmp
curl -s -O https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst
curl -s -O https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst
pacman -U --noconfirm chaotic-keyring.pkg.tar.zst chaotic-mirrorlist.pkg.tar.zst || true
# append repo include (if not present)
if ! grep -q 'chaotic-aur' /etc/pacman.conf 2>/dev/null; then
  cat >> /etc/pacman.conf <<CHAOTIC
[chaotic-aur]
Include = /etc/pacman.d/chaotic-mirrorlist
CHAOTIC
fi
pacman -Sy --noconfirm

# --- Step 10.10 install paru (AUR helper) from AUR ---
pacman -S --noconfirm --needed git base-devel
cd /tmp
if [[ ! -d paru ]]; then
  git clone https://aur.archlinux.org/paru.git
fi
cd paru
makepkg -si --noconfirm || true

# --- Step 10.11 install preload & booster (prefer official repos, fallback to paru) ---
if pacman -Qi preload &>/dev/null; then
  pacman -S --noconfirm preload || true
else
  if command -v paru &>/dev/null; then
    paru -S --noconfirm preload || true
  fi
fi

# booster: prefer repo then AUR if needed
if pacman -Qi booster &>/dev/null; then
  pacman -S --noconfirm booster || true
else
  if command -v paru &>/dev/null; then
    paru -S --noconfirm booster || true
  fi
fi

# ensure pigz, mold, ninja present
pacman -S --noconfirm --needed pigz mold ninja || true

# --- Step 10.12 write rust.conf (makepkg conf.d) ---
mkdir -p /etc/makepkg.conf.d
cat > /etc/makepkg.conf.d/rust.conf <<'RUSTCFG'
#!/hint/bash
# shellcheck disable=2034
RUSTFLAGS="-C target-cpu=native -C opt-level=3 -C link-arg=-fuse-ld=mold -C strip=symbols"
DEBUG_RUSTFLAGS="-C debuginfo=2"
CARGO_INCREMENTAL=0
RUSTCFG

# --- Step 10.13 tune /etc/makepkg.conf safely (back up first) ---
cp /etc/makepkg.conf /etc/makepkg.conf.orig || true
cat > /etc/makepkg.conf <<'MAKECFG'
# /etc/makepkg.conf (Cerebro tuned)
PKGDEST=/var/cache/pacman/pkg
SRCDEST=/var/tmp/src
SRCPKGDEST=/var/tmp/srcpkg
PKGEXT='.pkg.tar.lz4'

CFLAGS="-march=native -O3 -pipe"
CXXFLAGS="$CFLAGS"
CPPFLAGS=""
LDFLAGS="-Wl,-O1"

MAKEFLAGS="-j$(nproc)"
NINJAFLAGS="-j$(nproc)"
LTOFLAGS="-flto"

OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto)
COMPRESSZST=(zstd -c -T0 --long=30)
COMPRESSLZ4=(lz4 -q --no-frame-crc)
COMPRESSGZ=(pigz -c -f -n)
MAKECFG

# --- Step 10.14 regenerate initramfs (ensure resume hook present) ---
mkinitcpio -P

# chroot end
CHROOT_EOF

# -----------------------------
# Step 11: EFISTUB boot entries (run from host; ESP is mounted at /mnt/boot)
# -----------------------------
echo "[STEP 11] Creating EFISTUB entries..."
ROOT_UUID=$(blkid -s UUID -o value "$ROOT")
SWAP_UUID=$(blkid -s UUID -o value "$SWAP")

# vanilla Zen
efibootmgr -c -d "$DISK" -p 1 -L "Cerebro inicpio" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\\intel-ucode.img initrd=\\initramfs-linux-zen.img root=UUID=${ROOT_UUID} rw quiet resume=UUID=${SWAP_UUID}"

# booster entry (initrd path must be exactly that booster creates)
efibootmgr -c -d "$DISK" -p 1 -L "Cerebro booster" \
  -l '\vmlinuz-linux-zen' \
  -u "initrd=\\booster-linux-zen.img root=UUID=${ROOT_UUID} rw quiet resume=UUID=${SWAP_UUID}"

# -----------------------------
# Step 12: finish
# -----------------------------
echo
echo "✅ Installation finished."
echo " - Hostname: cerebro"
echo " - root / j passwords set to 777 (change immediately after first boot!)"
echo " - Reboot when ready: umount -R /mnt; swapoff -a; reboot"

# end of script

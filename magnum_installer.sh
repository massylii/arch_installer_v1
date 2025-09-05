#!/usr/bin/env bash
# arch_auto_install.sh
# One-shot installer: LUKS2 + Btrfs + UKI + Secure Boot
# Run as root from Arch ISO

set -euo pipefail
IFS=$'\n\t'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log(){ echo -e "${GREEN}[+] $*${NC}"; }
warn(){ echo -e "${YELLOW}[!] $*${NC}"; }
error(){ echo -e "${RED}[ERROR] $*${NC}"; exit 1; }
info(){ echo -e "${BLUE}[*] $*${NC}"; }

[[ $EUID -eq 0 ]] || error "Run as root (from Arch live ISO)"
[[ -d /sys/firmware/efi/efivars ]] || error "UEFI required"

# Defaults (edit before running if desired)
SWAP_SIZE="8G"
HOSTNAME="archbtw"
TIMEZONE="Africa/Algiers"
LOCALE="en_US.UTF-8"
KEYMAP="us"

timedatectl set-ntp true

# Disk selection
info "Available disks:"; lsblk -d -o NAME,SIZE,TYPE,MODEL
read -rp "Install to which disk (e.g. sda or /dev/nvme0n1): " DISK_INPUT
[[ -n "$DISK_INPUT" ]] || error "No disk given"
if [[ "$DISK_INPUT" == /dev/* ]]; then DISK="$DISK_INPUT"; else DISK="/dev/$DISK_INPUT"; fi
[[ -b "$DISK" ]] || error "Disk $DISK not found"

# CPU microcode detection
MICROCODE=""
if grep -qi "AuthenticAMD" /proc/cpuinfo 2>/dev/null; then MICROCODE="amd-ucode"; fi
if grep -qi "GenuineIntel" /proc/cpuinfo 2>/dev/null; then MICROCODE="intel-ucode"; fi

# GPU
echo -e "\n1) NVIDIA proprietary\n2) NVIDIA nouveau\n3) AMD\n4) Intel\n5) None"
read -rp "GPU type [5]: " GPU_CHOICE
GPU_CHOICE=${GPU_CHOICE:-5}

# Username
read -rp "New username: " USERNAME
[[ -n "$USERNAME" ]] || error "Username empty"

# Confirm
clear
echo "Disk: $DISK"
echo "User: $USERNAME"
echo "Swap size: $SWAP_SIZE"
echo "Microcode: ${MICROCODE:-none}"
warn "THIS WILL ERASE $DISK!"
read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || error "Aborted by user"

# Partitioning (1 GiB EFI)
log "Partitioning $DISK (1GiB EFI + rest)"
parted --script "$DISK" mklabel gpt
parted --script "$DISK" mkpart primary fat32 1MiB 1025MiB
parted --script "$DISK" set 1 esp on
parted --script "$DISK" mkpart primary 1025MiB 100%

if [[ "$DISK" == *nvme* ]]; then
  EFI_PART="${DISK}p1"
  ROOT_PART="${DISK}p2"
else
  EFI_PART="${DISK}1"
  ROOT_PART="${DISK}2"
fi
log "EFI: $EFI_PART   ROOT: $ROOT_PART"

# LUKS2 encrypt root
log "Formatting LUKS2 on $ROOT_PART (you will be prompted for a passphrase)"
cryptsetup luksFormat \
  --type luks2 --cipher aes-xts-plain64 --hash sha512 \
  --iter-time 5000 --key-size 512 --pbkdf argon2id \
  --use-urandom --verify-passphrase "$ROOT_PART"

log "Opening LUKS container"
cryptsetup open "$ROOT_PART" cryptroot

# Filesystems
log "Creating filesystems"
mkfs.fat -F32 -n ARCH_EFI "$EFI_PART"
mkfs.btrfs -f -L Arch_Root /dev/mapper/cryptroot

# Btrfs subvolumes
log "Creating Btrfs subvolumes"
mount /dev/mapper/cryptroot /mnt
for sub in @ @home @var @tmp @.snapshots; do
  btrfs subvolume create /mnt/$sub
done
umount /mnt

# Mount subvolumes with recommended options
BTRFS_OPTS="noatime,space_cache=v2,compress=zstd:3"
mount -o subvol=@,$BTRFS_OPTS /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{efi,home,var,tmp,.snapshots}
mount -o subvol=@home,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/home
mount -o subvol=@var,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/var
mount -o subvol=@tmp,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/tmp
mount -o subvol=@.snapshots,$BTRFS_OPTS /dev/mapper/cryptroot /mnt/.snapshots
mount "$EFI_PART" /mnt/efi

# Install base packages (added binutils for objcopy)
PACKAGES=(base linux linux-headers linux-firmware btrfs-progs base-devel \
          vim nano git cryptsetup sbctl efibootmgr dosfstools os-prober \
          sudo networkmanager binutils)
[[ -n "$MICROCODE" ]] && PACKAGES+=("$MICROCODE")
case $GPU_CHOICE in
  1) PACKAGES+=(nvidia nvidia-utils nvidia-settings) ;;
  2) PACKAGES+=(xf86-video-nouveau) ;;
  3) PACKAGES+=(mesa vulkan-radeon) ;;
  4) PACKAGES+=(mesa libva-intel-driver intel-media-driver) ;;
esac

log "Installing packages (pacstrap)"
pacstrap /mnt "${PACKAGES[@]}"

log "Generating fstab"
genfstab -U /mnt > /mnt/etc/fstab

# Create chroot script (will be executed inside new system)
log "Writing /root/arch_chroot.sh (inside new system)"
cat > /mnt/root/arch_chroot.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[+] $*"; }
warn(){ echo "[!] $*"; }
error(){ echo "[ERROR] $*"; exit 1; }

# Root password
echo "[*] Set root password:"
passwd

# Create user
useradd -m -G wheel -s /bin/bash __USERNAME__
echo "[*] Set password for __USERNAME__:"
passwd __USERNAME__

# Hostname, locale, timezone
echo "__HOSTNAME__" > /etc/hostname
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime
hwclock --systohc

# Enable locale (expand placeholder)
sed -i "s/^#\(__LOCALE__ UTF-8\)/\1/" /etc/locale.gen || true
locale-gen
echo "LANG=__LOCALE__" > /etc/locale.conf
echo "KEYMAP=__KEYMAP__" > /etc/vconsole.conf

# mkinitcpio hooks: use systemd + sd-encrypt (no legacy 'encrypt')
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf || true

# Build initramfs
log "Building initramfs"
mkinitcpio -P

# systemd-boot install (ESP is mounted at /efi inside chroot)
log "Installing systemd-boot to ESP (/efi)"
bootctl install --esp-path=/efi

# Create btrfs swapfile safely
log "Creating btrfs swapfile (/swapfile) size=__SWAP_SIZE__"
rm -f /swapfile || true
btrfs filesystem mkswapfile --size __SWAP_SIZE__ /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
if ! grep -q "^/swapfile" /etc/fstab; then
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

# Secure Boot: create keys and enroll (you will confirm enrollment at boot)
log "Creating Secure Boot keys with sbctl"
if ! sbctl create-keys; then
  warn "Failed to create Secure Boot keys, continuing without Secure Boot"
  SECURE_BOOT=false
else
  SECURE_BOOT=true
  log "Enrolling Secure Boot keys (manual mode - confirm at next boot)"
  sbctl enroll-keys -m
fi

# Prepare kernel cmdline for UKI (systemd format)
ROOT_UUID=$(blkid -s UUID -o value __ROOT_PART__)
if [[ -z "$ROOT_UUID" ]]; then
  error "Could not get root UUID"
fi
KERNEL_CMDLINE="rd.luks.name=$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"

# Determine microcode path if installed
MICROCODE_PATH=""
if [[ -n "__MICROCODE__" && -f /boot/__MICROCODE__.img ]]; then
  MICROCODE_PATH="/boot/__MICROCODE__.img"
  log "Including microcode: __MICROCODE__"
fi

# Create UKI directory on ESP
mkdir -p /efi/EFI/Linux

# Create combined initrd with microcode (proper method)
create_combined_initrd() {
  local output_file="$1"
  local initrd_file="$2"
  
  rm -f "$output_file" 2>/dev/null || true
  
  if [[ -n "$MICROCODE_PATH" && -f "$MICROCODE_PATH" ]]; then
    cat "$MICROCODE_PATH" "$initrd_file" > "$output_file"
  else
    cp "$initrd_file" "$output_file"
  fi
}

# Build main UKI
log "Building main UKI (/efi/EFI/Linux/arch.efi)"
create_combined_initrd /tmp/combined-initrd.img /boot/initramfs-linux.img

objcopy \
  --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=<(echo "$KERNEL_CMDLINE") --change-section-vma .cmdline=0x30000 \
  --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \
  --add-section .initrd=/tmp/combined-initrd.img --change-section-vma .initrd=0x3000000 \
  /usr/lib/systemd/boot/efi/linuxx64.efi.stub /efi/EFI/Linux/arch.efi

# Build fallback UKI if fallback initrd exists
if [[ -f /boot/initramfs-linux-fallback.img ]]; then
  log "Building fallback UKI (/efi/EFI/Linux/arch-fallback.efi)"
  create_combined_initrd /tmp/combined-initrd-fallback.img /boot/initramfs-linux-fallback.img
  
  objcopy \
    --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \
    --add-section .cmdline=<(echo "$KERNEL_CMDLINE") --change-section-vma .cmdline=0x30000 \
    --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \
    --add-section .initrd=/tmp/combined-initrd-fallback.img --change-section-vma .initrd=0x3000000 \
    /usr/lib/systemd/boot/efi/linuxx64.efi.stub /efi/EFI/Linux/arch-fallback.efi
fi

# Sign UKIs if Secure Boot is enabled
if [[ "$SECURE_BOOT" == true ]]; then
  log "Signing UKIs"
  if sbctl sign -s /efi/EFI/Linux/arch.efi; then
    log "Signed main UKI"
  else
    warn "Failed to sign main UKI"
  fi
  
  if [[ -f /efi/EFI/Linux/arch-fallback.efi ]]; then
    if sbctl sign -s /efi/EFI/Linux/arch-fallback.efi; then
      log "Signed fallback UKI"
    else
      warn "Failed to sign fallback UKI"
    fi
  fi
else
  warn "UKIs not signed (Secure Boot disabled)"
fi

# Configure systemd-boot loader to point at UKI
mkdir -p /efi/loader
cat > /efi/loader/loader.conf <<LOADER
default arch.efi
timeout 3
console-mode max
editor no
LOADER

# Create systemd-boot entry for UKI
mkdir -p /efi/loader/entries
cat > /efi/loader/entries/arch.conf <<ENTRY
title Arch Linux
efi /EFI/Linux/arch.efi
options rd.luks.name=$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY

if [[ -f /efi/EFI/Linux/arch-fallback.efi ]]; then
  cat > /efi/loader/entries/arch-fallback.conf <<ENTRY
title Arch Linux (fallback)
efi /EFI/Linux/arch-fallback.efi
options rd.luks.name=$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw
ENTRY
fi

# Clean temp files
rm -f /tmp/combined-initrd.img /tmp/combined-initrd-fallback.img 2>/dev/null || true

# Verify UKI creation
if [[ ! -f /efi/EFI/Linux/arch.efi ]]; then
  error "Main UKI creation failed!"
fi

log "UKI created successfully: /efi/EFI/Linux/arch.efi"

# Enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# Sudoers
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

log "CHROOT STEP COMPLETE. Exit chroot, unmount and reboot when ready."
log "Note: You will need to confirm Secure Boot key enrollment at next boot if enabled."
EOF

# Replace placeholders in chroot script
sed -i "s|__USERNAME__|$USERNAME|g" /mnt/root/arch_chroot.sh
sed -i "s|__HOSTNAME__|$HOSTNAME|g" /mnt/root/arch_chroot.sh
sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/root/arch_chroot.sh
sed -i "s|__LOCALE__|$LOCALE|g" /mnt/root/arch_chroot.sh
sed -i "s|__KEYMAP__|$KEYMAP|g" /mnt/root/arch_chroot.sh
sed -i "s|__SWAP_SIZE__|$SWAP_SIZE|g" /mnt/root/arch_chroot.sh
sed -i "s|__ROOT_PART__|$ROOT_PART|g" /mnt/root/arch_chroot.sh
sed -i "s|__MICROCODE__|$MICROCODE|g" /mnt/root/arch_chroot.sh

chmod +x /mnt/root/arch_chroot.sh

log "Run the chroot script now to finish setup (still inside live ISO):"
log "  arch-chroot /mnt /root/arch_chroot.sh"

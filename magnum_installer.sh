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

# Install base packages
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

# Create chroot script with ACTUAL VALUES instead of placeholders
log "Creating /root/arch_chroot.sh with actual values"
cat > /mnt/root/arch_chroot.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

log(){ echo "[+] \$*"; }
warn(){ echo "[!] \$*"; }
error(){ echo "[ERROR] \$*"; exit 1; }

# Root password
echo "[*] Set root password:"
passwd

# Create user
useradd -m -G wheel -s /bin/bash $USERNAME
echo "[*] Set password for $USERNAME:"
passwd $USERNAME

# Hostname, locale, timezone
echo "$HOSTNAME" > /etc/hostname
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Enable locale
sed -i "s/^#($LOCALE UTF-8)/\1/" /etc/locale.gen || true
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# mkinitcpio hooks
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block sd-encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf || true

# Build initramfs
log "Building initramfs"
mkinitcpio -P

# Create btrfs swapfile safely
log "Creating btrfs swapfile (/swapfile) size=$SWAP_SIZE"
swapoff /swapfile 2>/dev/null || true
rm -f /swapfile 2>/dev/null || true

# Try btrfs command first, then fallback
if btrfs filesystem mkswapfile --size $SWAP_SIZE /swapfile 2>/dev/null; then
    log "Swapfile created using btrfs command"
else
    warn "Using manual swapfile creation"
    truncate -s 0 /swapfile
    chattr +C /swapfile
    if [[ "$SWAP_SIZE" == *G ]]; then
        size_gb=\${SWAP_SIZE%G}
        dd if=/dev/zero of=/swapfile bs=1M count=\$((size_gb * 1024)) status=progress
    elif [[ "$SWAP_SIZE" == *M ]]; then
        size_mb=\${SWAP_SIZE%M}
        dd if=/dev/zero of=/swapfile bs=1M count=\$size_mb status=progress
    else
        dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
    fi
fi

chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap defaults 0 0" >> /etc/fstab

# Secure Boot
log "Creating Secure Boot keys with sbctl"
SECURE_BOOT=false
if sbctl create-keys; then
    SECURE_BOOT=true
    log "Enrolling Secure Boot keys (manual mode)"
    sbctl enroll-keys -m
else
    warn "Failed to create Secure Boot keys"
fi

# Prepare kernel cmdline for UKI
ROOT_UUID=\$(blkid -s UUID -o value $ROOT_PART)
[[ -z "\$ROOT_UUID" ]] && error "Could not get root UUID"
KERNEL_CMDLINE="rd.luks.name=\$ROOT_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw"

# Determine microcode path
MICROCODE_PATH=""
if [[ -n "$MICROCODE" && -f /boot/$MICROCODE.img ]]; then
    MICROCODE_PATH="/boot/$MICROCODE.img"
    log "Including microcode: $MICROCODE"
fi

# Create UKI directory
mkdir -p /efi/EFI/Linux

# Create combined initrd
create_combined_initrd() {
    local output_file="\$1"
    local initrd_file="\$2"
    rm -f "\$output_file" 2>/dev/null || true
    if [[ -n "\$MICROCODE_PATH" && -f "\$MICROCODE_PATH" ]]; then
        cat "\$MICROCODE_PATH" "\$initrd_file" > "\$output_file"
    else
        cp "\$initrd_file" "\$output_file"
    fi
}

# Build main UKI
log "Building main UKI"
create_combined_initrd /tmp/combined-initrd.img /boot/initramfs-linux.img
echo "\$KERNEL_CMDLINE" > /tmp/cmdline

objcopy \\
  --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \\
  --add-section .cmdline=/tmp/cmdline --change-section-vma .cmdline=0x30000 \\
  --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \\
  --add-section .initrd=/tmp/combined-initrd.img --change-section-vma .initrd=0x3000000 \\
  /usr/lib/systemd/boot/efi/linuxx64.efi.stub /efi/EFI/Linux/arch.efi

# Build fallback UKI if exists
if [[ -f /boot/initramfs-linux-fallback.img ]]; then
    log "Building fallback UKI"
    create_combined_initrd /tmp/combined-initrd-fallback.img /boot/initramfs-linux-fallback.img
    objcopy \\
      --add-section .osrel=/etc/os-release --change-section-vma .osrel=0x20000 \\
      --add-section .cmdline=/tmp/cmdline --change-section-vma .cmdline=0x30000 \\
      --add-section .linux=/boot/vmlinuz-linux --change-section-vma .linux=0x2000000 \\
      --add-section .initrd=/tmp/combined-initrd-fallback.img --change-section-vma .initrd=0x3000000 \\
      /usr/lib/systemd/boot/efi/linuxx64.efi.stub /efi/EFI/Linux/arch-fallback.efi
fi

# Sign UKIs if Secure Boot enabled
if [[ "\$SECURE_BOOT" == true ]]; then
    log "Signing UKIs"
    sbctl sign -s /efi/EFI/Linux/arch.efi
    [[ -f /efi/EFI/Linux/arch-fallback.efi ]] && sbctl sign -s /efi/EFI/Linux/arch-fallback.efi
fi

# Create UEFI boot entry
log "Creating UEFI boot entry"
EFI_DISK=\$(lsblk -no pkname $ROOT_PART | head -1)
if [[ -n "\$EFI_DISK" ]]; then
    efibootmgr --create --disk "/dev/\$EFI_DISK" --part 1 --label "Arch Linux" --loader '\\EFI\\Linux\\arch.efi' --unicode
fi

# Clean up
rm -f /tmp/cmdline /tmp/combined-initrd*.img 2>/dev/null || true

# Enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# Sudoers
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

log "CHROOT STEP COMPLETE. Exit chroot, unmount and reboot."
EOF

chmod +x /mnt/root/arch_chroot.sh

log "Chroot script created successfully with actual values"
log "Run: arch-chroot /mnt /root/arch_chroot.sh"

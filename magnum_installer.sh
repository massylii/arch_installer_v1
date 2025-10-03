#!/bin/bash
set -e

# Arch Linux Secure Installation Script
# Features: BTRFS, LUKS2 with 512-bit encryption, Secure Boot support
# Target disk: /dev/sda

echo "=========================================="
echo "Arch Linux Secure Installation"
echo "LUKS2 + BTRFS + Secure Boot"
echo "=========================================="
echo ""
echo "WARNING: This will ERASE ALL DATA on /dev/sda"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Installation cancelled."
    exit 1
fi

# Variables
DISK="/dev/sda"
EFI_PART="${DISK}1"
ROOT_PART="${DISK}2"
CRYPT_NAME="cryptroot"

echo ""
read -p "Enter your hostname: " HOSTNAME
read -p "Enter your username: " USERNAME
read -p "Intel or AMD CPU? (intel/amd): " CPU_VENDOR

if [ "$CPU_VENDOR" = "intel" ]; then
    UCODE="intel-ucode"
elif [ "$CPU_VENDOR" = "amd" ]; then
    UCODE="amd-ucode"
else
    echo "Invalid CPU vendor. Please enter 'intel' or 'amd'."
    exit 1
fi

echo ""
echo "=========================================="
echo "Starting installation..."
echo "=========================================="

# Partition the disk
echo ""
echo "Partitioning disk..."
parted -s $DISK mklabel gpt
parted -s $DISK mkpart primary fat32 1MiB 1025MiB
parted -s $DISK set 1 esp on
parted -s $DISK mkpart primary 1025MiB 100%

# Format EFI partition
echo ""
echo "Formatting EFI partition..."
mkfs.fat -F32 $EFI_PART

# Setup LUKS2 encryption with strong settings
echo ""
echo "Setting up LUKS2 encryption with 512-bit key..."
echo "Using strong encryption: aes-xts-plain64 with 512-bit key and argon2id"
cryptsetup luksFormat --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --pbkdf-memory 1048576 \
    --pbkdf-parallel 4 \
    --iter-time 5000 \
    $ROOT_PART

echo ""
echo "Opening encrypted partition..."
cryptsetup open $ROOT_PART $CRYPT_NAME

# Format with BTRFS
echo ""
echo "Creating BTRFS filesystem..."
mkfs.btrfs -L ArchLinux /dev/mapper/$CRYPT_NAME

# Mount and create subvolumes
echo ""
echo "Creating BTRFS subvolumes..."
mount /dev/mapper/$CRYPT_NAME /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# Mount subvolumes
echo ""
echo "Mounting subvolumes..."
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@ /dev/mapper/$CRYPT_NAME /mnt
mkdir -p /mnt/{home,var,.snapshots,boot,efi}
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@home /dev/mapper/$CRYPT_NAME /mnt/home
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@var /dev/mapper/$CRYPT_NAME /mnt/var
mount -o noatime,compress=zstd:1,space_cache=v2,subvol=@snapshots /dev/mapper/$CRYPT_NAME /mnt/.snapshots
mount $EFI_PART /mnt/efi

# Install base system with secure boot tools
echo ""
echo "Installing base system..."
pacstrap /mnt base linux linux-firmware linux-headers $UCODE sudo vim mkinitcpio \
    git efibootmgr networkmanager btrfs-progs sbctl

# Generate fstab
echo ""
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot and configure
echo ""
echo "Configuring system..."

arch-chroot /mnt /bin/bash <<EOF
set -e

# Set root password
echo ""
echo "Set root password:"
passwd

# Install additional packages
pacman -Syu --noconfirm man-db htop

# Create user
useradd -m -G wheel $USERNAME
echo ""
echo "Set password for $USERNAME:"
passwd $USERNAME

# Configure sudo
sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers

# Set hostname
echo "$HOSTNAME" > /etc/hostname

# Configure hosts
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOL

# Set timezone (adjust as needed)
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc

# Generate locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# Configure mkinitcpio for encryption
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf

# Install systemd-boot
bootctl install

# Get UUID of encrypted partition
UUID=\$(blkid -s UUID -o value $ROOT_PART)

# Create kernel command line
mkdir -p /etc/kernel
echo "rd.luks.name=\${UUID}=$CRYPT_NAME root=/dev/mapper/$CRYPT_NAME rootflags=subvol=@ rw quiet splash lsm=landlock,lockdown,yama,integrity,apparmor,bpf" > /etc/kernel/cmdline

# Configure UKI in linux preset
cat > /etc/mkinitcpio.d/linux.preset <<PRESET
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux"
ALL_microcode=(/boot/*-ucode.img)

PRESETS=('default' 'fallback')

default_uki="/efi/EFI/Linux/arch-linux.efi"
default_options="--splash /usr/share/systemd/bootctl/splash-arch.bmp"

fallback_uki="/efi/EFI/Linux/arch-linux-fallback.efi"
fallback_options="-S autodetect"
PRESET

# Regenerate initramfs
mkinitcpio -P

# Configure systemd-boot
cat > /efi/loader/loader.conf <<LOADER
default arch-linux.efi
timeout 3
console-mode max
editor no
LOADER

# Setup Secure Boot
echo ""
echo "Setting up Secure Boot..."
echo "Creating and enrolling Secure Boot keys..."

# Create Secure Boot keys
sbctl create-keys

# Enroll keys (with Microsoft keys for compatibility)
sbctl enroll-keys -m

# Sign bootloader and kernel
sbctl sign -s /efi/EFI/BOOT/BOOTX64.EFI
sbctl sign -s /efi/EFI/systemd/systemd-bootx64.efi
sbctl sign -s /efi/EFI/Linux/arch-linux.efi
sbctl sign -s /efi/EFI/Linux/arch-linux-fallback.efi

# Verify signing
echo ""
echo "Verifying Secure Boot signatures..."
sbctl verify

echo ""
echo "=========================================="
echo "Installation complete!"
echo "=========================================="
echo ""
echo "System configured with:"
echo "- BTRFS filesystem with subvolumes"
echo "- LUKS2 encryption (AES-XTS-512, Argon2id)"
echo "- Secure Boot ready (keys enrolled)"
echo "- User: $USERNAME"
echo "- Hostname: $HOSTNAME"
echo ""
echo "IMPORTANT POST-INSTALL STEPS:"
echo "1. Reboot and enter BIOS/UEFI settings"
echo "2. Enable Secure Boot"
echo "3. Set BIOS supervisor password (recommended)"
echo "4. Clear any old Secure Boot keys if needed"
echo ""
EOF

# Unmount and close
echo ""
echo "Unmounting filesystems..."
umount -R /mnt
cryptsetup close $CRYPT_NAME

echo ""
echo "=========================================="
echo "Installation finished successfully!"
echo "=========================================="
echo ""
echo "NEXT STEPS:"
echo "1. Remove the installation media"
echo "2. Reboot: reboot"
echo "3. Enter BIOS and enable Secure Boot"
echo "4. Boot into your new system"
echo "5. You'll be prompted for LUKS password"
echo "6. Check Secure Boot status: sbctl status"
echo ""
echo "Security features enabled:"
echo "✓ LUKS2 with 512-bit AES-XTS encryption"
echo "✓ Argon2id key derivation (5 second iteration)"
echo "✓ Secure Boot keys created and enrolled"
echo "✓ All boot components signed"
echo "✓ systemd-based encryption hooks"
echo ""

#!/bin/bash
# Arch Linux LUKS2 + Btrfs install script with UKI and SecureBoot
# Based on: https://github.com/xdakota/arch-install-guide
# Modified: LVM → Btrfs, stronger LUKS2 encryption

set -euo pipefail

# Configuration
DISK="/dev/sda"
EFI_SIZE="1024M"
HOSTNAME="archlinux"
USERNAME="archuser"
PASSWORD="password"
LUKS_PASSWORD="lukspassword"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"
UCODE="intel-ucode"  # Change to "amd-ucode" for AMD

# LUKS2 with Argon2id (strong 512-bit encryption)
LUKS_CIPHER="aes-xts-plain64"
LUKS_KEY_SIZE="512"
LUKS_HASH="sha512"
LUKS_ITER_TIME="5000"  # 5 seconds (very strong)
LUKS_PBKDF="argon2id"

echo "======================================"
echo "Arch Linux Encrypted Install Script"
echo "Disk: $DISK"
echo "LUKS: $LUKS_CIPHER with $LUKS_KEY_SIZE-bit key"
echo "======================================"
read -p "This will WIPE $DISK. Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# 1. Partition disk
echo "Creating partitions..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+${EFI_SIZE} -t 1:EF00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:8309 -c 2:"LUKS" "$DISK"

EFI_PART="${DISK}1"
LUKS_PART="${DISK}2"

# 2. Format EFI
echo "Formatting EFI partition..."
mkfs.fat -F32 "$EFI_PART"

# 3. Setup LUKS2 with strong encryption
echo "Setting up LUKS2 encryption (this will take ~${LUKS_ITER_TIME}ms per attempt)..."
echo -n "$LUKS_PASSWORD" | cryptsetup luksFormat \
    --type luks2 \
    --cipher "$LUKS_CIPHER" \
    --key-size "$LUKS_KEY_SIZE" \
    --hash "$LUKS_HASH" \
    --iter-time "$LUKS_ITER_TIME" \
    --pbkdf "$LUKS_PBKDF" \
    --use-random \
    "$LUKS_PART" -

echo -n "$LUKS_PASSWORD" | cryptsetup open --allow-discards --persistent "$LUKS_PART" cryptroot -

# 4. Create Btrfs filesystem
echo "Creating Btrfs filesystem..."
mkfs.btrfs -f /dev/mapper/cryptroot
mount /dev/mapper/cryptroot /mnt

# 5. Create Btrfs subvolumes
echo "Creating Btrfs subvolumes..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
umount /mnt

# 6. Mount subvolumes
echo "Mounting subvolumes..."
mount -o subvol=@,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,var,.snapshots,boot/efi}
mount -o subvol=@home,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt/home
mount -o subvol=@var,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt/var
mount -o subvol=@snapshots,compress=zstd:1,noatime /dev/mapper/cryptroot /mnt/.snapshots
mount "$EFI_PART" /mnt/boot/efi

# 7. Update mirrorlist for faster downloads
echo "Updating mirrorlist..."
pacman -Sy --noconfirm reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# 8. Install base system
echo "Installing base system..."
pacstrap -K /mnt base linux linux-firmware "$UCODE" sudo vim \
    btrfs-progs dracut sbctl sbsigntools efibootmgr iwd git networkmanager

# 9. Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Get UUIDs
LUKS_UUID=$(blkid -s UUID -o value "$LUKS_PART")

# 10. Chroot configuration
echo "Configuring system..."
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Root password
echo "root:$PASSWORD" | chpasswd

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# User creation
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Enable services
systemctl enable NetworkManager
systemctl enable fstrim.timer

# ====================================
# Dracut UKI Configuration
# ====================================

# Create dracut install script
cat > /usr/local/bin/dracut-install.sh <<'SCRIPT'
#!/usr/bin/env bash
mkdir -p /boot/efi/EFI/Linux

while read -r line; do
    if [[ "\$line" == 'usr/lib/modules/'+([^/])'/pkgbase' ]]; then
        kver="\${line#'usr/lib/modules/'}"
        kver="\${kver%'/pkgbase'}"
        
        dracut --force --uefi --kver "\$kver" /boot/efi/EFI/Linux/bootx64.efi
    fi
done
SCRIPT

# Create dracut remove script
cat > /usr/local/bin/dracut-remove.sh <<'SCRIPT'
#!/usr/bin/env bash
rm -f /boot/efi/EFI/Linux/bootx64.efi
SCRIPT

chmod +x /usr/local/bin/dracut-*.sh
mkdir -p /etc/pacman.d/hooks

# Dracut install hook
cat > /etc/pacman.d/hooks/90-dracut-install.hook <<'HOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Updating linux EFI image
When = PostTransaction
Exec = /usr/local/bin/dracut-install.sh
Depends = dracut
NeedsTargets
HOOK

# Dracut remove hook
cat > /etc/pacman.d/hooks/60-dracut-remove.hook <<'HOOK'
[Trigger]
Type = Path
Operation = Remove
Target = usr/lib/modules/*/pkgbase

[Action]
Description = Removing linux EFI image
When = PreTransaction
Exec = /usr/local/bin/dracut-remove.sh
NeedsTargets
HOOK

# ====================================
# SecureBoot Setup
# ====================================

# Create SecureBoot keys BEFORE generating UKI
echo "Creating SecureBoot keys..."
sbctl create-keys

# Dracut kernel cmdline
cat > /etc/dracut.conf.d/cmdline.conf <<CMDLINE
kernel_cmdline="rd.luks.uuid=luks-$LUKS_UUID root=/dev/mapper/cryptroot rootfstype=btrfs rootflags=subvol=@,rw,noatime,compress=zstd:1"
CMDLINE

# Dracut flags
cat > /etc/dracut.conf.d/flags.conf <<FLAGS
compress="zstd"
hostonly="no"
add_dracutmodules+=" crypt btrfs "
FLAGS

# SecureBoot configuration for dracut (NOW keys exist)
cat > /etc/dracut.conf.d/secureboot.conf <<SECUREBOOT
uefi_secureboot_cert="/var/lib/sbctl/keys/db/db.pem"
uefi_secureboot_key="/var/lib/sbctl/keys/db/db.key"
SECUREBOOT

# Generate UKI (will auto-sign with dracut)
echo "Generating Unified Kernel Image..."
pacman -S --noconfirm linux

# Verify UKI was created and sign with sbctl too
if [[ -f /boot/efi/EFI/Linux/bootx64.efi ]]; then
    echo "UKI created successfully, signing with sbctl..."
    sbctl sign -s /boot/efi/EFI/Linux/bootx64.efi
else
    echo "ERROR: UKI was not created!"
    exit 1
fi

# Override sbctl pacman hook
cat > /etc/pacman.d/hooks/zz-sbctl.hook <<SBCTL
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = boot/*
Target = efi/*
Target = usr/lib/modules/*/vmlinuz
Target = usr/lib/initcpio/*
Target = usr/lib/**/efi/*.efi*

[Action]
Description = Signing EFI binaries...
When = PostTransaction
Exec = /usr/bin/sbctl sign /boot/efi/EFI/Linux/bootx64.efi
SBCTL

# Enroll keys (with Microsoft keys for dual-boot compatibility)
echo "Enrolling SecureBoot keys..."
sbctl enroll-keys --microsoft

# ====================================
# UEFI Boot Entry
# ====================================

# Create UEFI boot entry
efibootmgr --create --disk $DISK --part 1 --label "Arch Linux" --loader 'EFI\Linux\bootx64.efi' --unicode

# Set boot order (get the number from last entry)
BOOT_NUM=\$(efibootmgr | grep "Arch Linux" | cut -d' ' -f1 | tr -d 'Boot*')
efibootmgr -o \$BOOT_NUM

echo "Boot entry created: \$BOOT_NUM"

EOF

# 11. Cleanup
echo "Unmounting filesystems..."
umount -R /mnt
cryptsetup close cryptroot

echo ""
echo "✅ Installation complete!"
echo ""
echo "======================================"
echo "NEXT STEPS:"
echo "======================================"
echo "1. Reboot your system"
echo "2. Enter BIOS/UEFI setup"
echo "3. Enable 'Setup Mode' for SecureBoot"
echo "4. Enable SecureBoot"
echo "5. Set BIOS password"
echo "6. Boot into Arch Linux"
echo "7. Enter LUKS password: $LUKS_PASSWORD"
echo ""
echo "Verify SecureBoot status with:"
echo "  sbctl status"
echo ""
echo "LUKS Encryption Details:"
echo "  Cipher: $LUKS_CIPHER"
echo "  Key Size: $LUKS_KEY_SIZE-bit"
echo "  PBKDF: $LUKS_PBKDF"
echo "  Iteration Time: ${LUKS_ITER_TIME}ms"
echo "======================================"

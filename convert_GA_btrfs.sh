#!/usr/bin/env bash
#
# Automates the conversion of an Ext4 root partition to Btrfs on Groovy Arcade Arch Linux
# Author: banane
#
#/ Usage: setup_btrfs.sh --root-partition DEVICE
#/
#/ OPTIONS:
#/   -h, --help              Show this help message
#/   --root-partition DEVICE  Specify the root partition (required)

# === Bash settings ===
set -o errexit  # Exit on error
set -o nounset  # Exit on uninitialized variables
set -o pipefail # Prevent hidden errors in pipelines

# === Global Variables ===
IFS=$'\t\n'  # Split on newlines and tabs (not spaces)
script_name=$(basename "$0")
script_dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

ROOT_PARTITION=""  # Must be specified via --root-partition
PARTITION_NUMBER=3
NEW_PARTITION=""
BOOT_PARTITION=""
SWAP_PARTITION=""
DISK_DEVICE=""
MOUNT_OLD="/mnt/old"
MOUNT_NEW="/mnt/new"

# ANSI Colors
GREEN='\e[1;32m' # Bright Green
RED='\e[1;31m'   # Bright Red
RESET='\e[0m'    # Reset color

# === Helper functions ===

# Print usage information
usage() {
  grep '^#/' "$script_name" | sed 's/^#\/\($\| \)//'
}

# Print an error message and exit (Red)
error() {
  printf "${RED}ERROR: %s${RESET}\n" "$*" >&2
  exit 1
}

# Print a log message (Green)
log() {
  printf "${GREEN}%s${RESET}\n" "$*"
}

# Process command-line arguments
process_args() {
  if [[ $# -eq 0 ]]; then
    error "No arguments provided. Use --root-partition DEVICE"
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --root-partition)
        shift
        if [[ $# -eq 0 ]]; then
          error "Missing argument for --root-partition"
        fi
        ROOT_PARTITION="$1"
        ;;
      -*)
        error "Unknown option: $1"
        ;;
      *)
        error "This script does not take positional arguments"
        ;;
    esac
    shift
  done

  if [[ -z "$ROOT_PARTITION" ]]; then
    error "--root-partition option is required"
  fi
}

# Ensure the script is run as root
check_root() {
  if [[ "$EUID" -ne 0 ]]; then
    error "This script must be run as root!"
  fi
}

# Create necessary mount points
create_mount_points() {
  log "Creating mount points..."
  sudo mkdir -p "$MOUNT_OLD"
  sudo mkdir -p "$MOUNT_NEW"
}

# Check if at least 50% of the partition is free
check_free_space() {
  log "Checking free space on $ROOT_PARTITION..."
  
  local mount_needed=false
  local used_percentage

  if ! mount | grep -q "$ROOT_PARTITION"; then
    log "Partition $ROOT_PARTITION is not mounted. Temporarily mounting to $MOUNT_OLD..."
    sudo mkdir -p "$MOUNT_OLD"
    sudo mount "$ROOT_PARTITION" "$MOUNT_OLD" || error "Failed to mount $ROOT_PARTITION for checking."
    mount_needed=true
  fi

  used_percentage=$(df --output=pcent "$MOUNT_OLD" | tail -1 | awk '{print $1}' | tr -d '%')

  if [[ "$mount_needed" == true ]]; then
    log "Unmounting from $MOUNT_OLD..."
    sudo umount "$MOUNT_OLD"
  fi

  if [[ -z "$used_percentage" ]]; then
    error "Failed to retrieve disk usage percentage for $ROOT_PARTITION."
  fi

  if [[ "$used_percentage" -ge 50 ]]; then
    error "Not enough free space on $ROOT_PARTITION! More than 50% is used ($used_percentage%). Free up space before proceeding."
  fi

  log "Sufficient free space available ($used_percentage% used)."
}

# Update the package manager and install required dependencies
update_package_manager() {
  log "Updating package list and installing required tools..."
  sudo pacman -Sy --noconfirm bc btrfs-progs
}

# Resize the root partition filesystem
resize_filesystem() {
  log "Resizing $ROOT_PARTITION filesystem to 50% of its current size..."

  local total_size_gb
  total_size_gb=$(lsblk -b -n -o SIZE "$ROOT_PARTITION" | awk '{print $1/1024/1024/1024}')
  
  local new_size_gb
  new_size_gb=$(echo "$total_size_gb / 2" | bc)

  log "Current filesystem size: ${total_size_gb}G, Resizing to: ${new_size_gb}G"

  sudo resize2fs "$ROOT_PARTITION" "${new_size_gb}G" || error "Failed to resize filesystem."
}

# Resize the root partition using fdisk
resize_partition() {
  log "Resizing $ROOT_PARTITION partition to 50% of its current size using fdisk..."

  DISK_DEVICE=$(lsblk -no PKNAME "$ROOT_PARTITION" | head -n 1)
  DISK_DEVICE="/dev/$DISK_DEVICE"

  if [[ -z "$DISK_DEVICE" || ! -b "$DISK_DEVICE" ]]; then
    error "Failed to determine the disk device for $ROOT_PARTITION."
  fi

  local total_size_gb
  total_size_gb=$(lsblk -b -n -o SIZE "$ROOT_PARTITION" | awk '{print $1/1024/1024/1024}')
  
  local new_size_gb
  new_size_gb=$(echo "$total_size_gb / 2" | bc)

  local start_sector
  start_sector=$(sudo fdisk -l "$DISK_DEVICE" | awk '$1 == "'"$ROOT_PARTITION"'" {print $2}')

  if [[ -z "$start_sector" ]]; then
    error "Failed to determine the start sector of $ROOT_PARTITION."
  fi

  log "Resizing partition using fdisk..."
  sudo fdisk "$DISK_DEVICE" <<EOF
d
$PARTITION_NUMBER
n
$PARTITION_NUMBER
$start_sector
+${new_size_gb}G
t
$PARTITION_NUMBER
83
w
EOF

  sudo partprobe "$DISK_DEVICE" || error "Failed to reload partition table. Try rebooting."
  log "Partition resizing completed."
}

# Check filesystem integrity
check_filesystem() {
  log "Checking filesystem on $ROOT_PARTITION..."
  sudo e2fsck -f "$ROOT_PARTITION" || error "Filesystem check failed."
}

# Create a new partition after the resized one
create_new_partition() {
  log "Creating a new partition after the resized root partition..."

  local new_partition_number=$((PARTITION_NUMBER + 1))

  # Get the end sector of the resized partition
  local last_partition_end
  last_partition_end=$(sudo fdisk -l "$DISK_DEVICE" | grep "$ROOT_PARTITION" | awk '{print $3}')


  if [[ -z "$last_partition_end" || ! "$last_partition_end" =~ ^[0-9]+$ ]]; then
    error "Failed to determine the end sector of the resized partition. Check fdisk output."
  fi

  local start_sector=$((last_partition_end + 1))

  log "Creating new partition $new_partition_number starting at sector $start_sector and using all available space."

  # Create the new partition using fdisk
  sudo fdisk "$DISK_DEVICE" <<EOF
n
$new_partition_number
$start_sector

t
$new_partition_number
83  # Set partition type to Linux filesystem
w
EOF

  # Reload partition table
  if ! sudo partprobe "$DISK_DEVICE"; then
    error "Failed to reload partition table. Try rebooting the system before proceeding."
  fi

  log "New partition $new_partition_number created successfully."

  # Verify the partition layout
  log "Verifying partition layout..."
  sudo fdisk -l "$DISK_DEVICE"
}

# Format the newly created partition as Btrfs
format_partition_as_btrfs() {
  log "Formatting the new partition as Btrfs..."

  NEW_PARTITION=$(lsblk -lnp -o NAME "$DISK_DEVICE" | tail -n 1)

  if [[ -z "$NEW_PARTITION" || ! -b "$NEW_PARTITION" ]]; then
    error "Failed to determine the newly created partition."
  fi

  log "New partition detected: $NEW_PARTITION"
  sudo mkfs.btrfs -f "$NEW_PARTITION" || error "Failed to format $NEW_PARTITION as Btrfs."

  log "Btrfs filesystem successfully created on $NEW_PARTITION."
}

# Create Btrfs subvolumes
create_btrfs_subvolumes() {
  log "Creating Btrfs subvolumes..."

  if ! sudo blkid "$NEW_PARTITION" | grep -q "TYPE=\"btrfs\""; then
    error "$NEW_PARTITION is not formatted as Btrfs!"
  fi

  sudo mount "$NEW_PARTITION" "$MOUNT_NEW" || error "Failed to mount $NEW_PARTITION."

  for subvol in "@" "@home" "@pkg" "@snapshots"; do
    log "Creating subvolume: $subvol"
    sudo btrfs subvolume create "$MOUNT_NEW/$subvol" || error "Failed to create subvolume $subvol."
  done

  sudo umount "$NEW_PARTITION" || error "Failed to umount $NEW_PARTITION."
  log "Btrfs subvolumes created successfully."
}

# Mount the new Btrfs partition and its subvolumes
mount_btrfs_partition() {
  log "Mounting Btrfs partition and subvolumes..."
  
  NEW_PARTITION="/dev/mmcblk0p4"

  if [[ -z "$NEW_PARTITION" || ! -b "$NEW_PARTITION" ]]; then
    error "NEW_PARTITION is not set or not a valid block device."
  fi

  sudo mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@ "$NEW_PARTITION" "$MOUNT_NEW" || error "Failed to mount root subvolume."

  sudo mkdir -p "$MOUNT_NEW/home"
  sudo mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@home "$NEW_PARTITION" "$MOUNT_NEW/home" || error "Failed to mount @home subvolume."

  sudo mkdir -p "$MOUNT_NEW/var/cache/pacman/pkg"
  sudo mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@pkg "$NEW_PARTITION" "$MOUNT_NEW/var/cache/pacman/pkg" || error "Failed to mount @pkg subvolume."

  sudo mkdir -p "$MOUNT_NEW/.snapshots"
  sudo mount -o noatime,compress=lzo,space_cache=v2,ssd,subvol=@snapshots "$NEW_PARTITION" "$MOUNT_NEW/.snapshots" || error "Failed to mount @snapshots subvolume."

  sudo mkdir -p "$MOUNT_NEW/btrfs"
  sudo mount -o noatime,compress=lzo,space_cache=v2,ssd,subvolid=5 "$NEW_PARTITION" "$MOUNT_NEW/btrfs" || error "Failed to mount Btrfs root."

  # Mount old system and boot partition
  sudo mount "$ROOT_PARTITION" "$MOUNT_OLD" || error "Failed to mount old root partition."

  # Derive boot and swap partitions from ROOT_PARTITION
  local BASE_DEVICE="$(lsblk -no PKNAME "$ROOT_PARTITION")"
  BOOT_PARTITION="/dev/${BASE_DEVICE}p1"
  SWAP_PARTITION="/dev/${BASE_DEVICE}p2"
 
  sudo mkdir -p "$MOUNT_NEW/boot"
  sudo mount "/dev/mmcblk0p1" "$MOUNT_NEW/boot" || error "Failed to mount boot partition."
  
  log "All partitions and subvolumes successfully mounted."
}

# Copy filesystem from old partition to new partition
copy_filesystem() {
  log "Copying filesystem from old partition to new partition..."
  sudo rsync -aAXv /mnt/old/ /mnt/new/ || error "Filesystem copy failed."
  log "Filesystem successfully copied."
}

# Update the bootloader with the new UUID and subvolume
update_bootloader() {
  log "Updating bootloader with new UUID and subvolume..."

  NEW_PARTITION="/dev/mmcblk0p4"

  local NEW_UUID=$(sudo btrfs filesystem show "$NEW_PARTITION" | awk '/uuid/ {print $4}')
  if [[ -z "$NEW_UUID" ]]; then
    error "Failed to retrieve UUID for new partition."
  fi

  BOOTLOADER_CONFIG="$MOUNT_NEW/boot/EFI/syslinux/syslinux.cfg"

  if [[ ! -f "$BOOTLOADER_CONFIG" ]]; then
    error "Bootloader configuration file not found: $BOOTLOADER_CONFIG"
  fi

  sudo sed -i "s|root=/dev/disk/by-uuid/[a-f0-9-]*|root=/dev/disk/by-uuid/$NEW_UUID rootflags=subvol=@,compress=lzo,noatime,space_cache=v2|" "$BOOTLOADER_CONFIG"
  
  log "Bootloader updated successfully with new UUID: $NEW_UUID and btrfs rootflags"
}

# Update fstab with new UUIDs and mount options
update_fstab() {
  log "Updating fstab with new UUIDs and mount options..."

  local NEW_UUID=$(sudo btrfs filesystem show "$NEW_PARTITION" | awk '/uuid/ {print $4}')
  local BOOT_UUID=$(sudo blkid -s UUID -o value "$BOOT_PARTITION")
  local SWAP_UUID=$(sudo blkid -s UUID -o value "$SWAP_PARTITION")

  cat <<EOF | sudo tee "$MOUNT_NEW/etc/fstab"
UUID=$NEW_UUID    /                    btrfs   rw,noatime,compress=lzo,ssd,space_cache=v2,subvol=@              0 0
UUID=$NEW_UUID    /home                btrfs   rw,noatime,compress=lzo,ssd,space_cache=v2,subvol=@home          0 0
UUID=$NEW_UUID    /var/cache/pacman/pkg btrfs   rw,noatime,compress=lzo,ssd,space_cache=v2,subvol=@pkg           0 0
UUID=$NEW_UUID    /.snapshots          btrfs   rw,noatime,compress=lzo,ssd,space_cache=v2,subvol=@snapshots      0 0
UUID=$NEW_UUID    /btrfs               btrfs   rw,noatime,compress=lzo,ssd,space_cache=v2,subvolid=5             0 0

UUID=$BOOT_UUID   /boot                vfat    rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro  0 2
UUID=$SWAP_UUID   none                 swap    defaults                                                              0 0
EOF

  log "fstab updated successfully."
}

# Update mkinitcpio.conf to include btrfs hook and regenerate initramfs
update_mkinitcpio() {
  log "Updating mkinitcpio.conf to include btrfs hook..."
  local MKINITCPIO_CONFIG="$MOUNT_NEW/etc/mkinitcpio.conf"

  if [[ ! -f "$MKINITCPIO_CONFIG" ]]; then
    error "mkinitcpio.conf not found: $MKINITCPIO_CONFIG"
  fi

  sudo sed -i 's|HOOKS=(|HOOKS=(btrfs |' "$MKINITCPIO_CONFIG"
  log "mkinitcpio.conf updated successfully."

  log "Installing btrfs-progs inside chroot..."
  sudo arch-chroot "$MOUNT_NEW" pacman -Sy --noconfirm btrfs-progs || error "Failed to install btrfs-progs."

  log "Regenerating initramfs..."
  sudo arch-chroot "$MOUNT_NEW" mkinitcpio -P || error "Failed to regenerate initramfs."
  log "Initramfs regenerated successfully."
}



# === Main function ===
main() {
  process_args "$@"
  check_root
  create_mount_points
  check_free_space
  update_package_manager

  check_filesystem
  resize_filesystem
  resize_partition
  check_filesystem

  create_new_partition
  format_partition_as_btrfs
  create_btrfs_subvolumes
  mount_btrfs_partition
  copy_filesystem

  update_bootloader
  update_fstab
  update_mkinitcpio

  log "Setup completed!"
}

# Execute main function
main "$@"

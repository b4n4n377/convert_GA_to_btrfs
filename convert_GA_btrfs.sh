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

  # Check if the partition is already mounted
  if ! mount | grep -q "$ROOT_PARTITION"; then
    log "Partition $ROOT_PARTITION is not mounted. Temporarily mounting to $MOUNT_OLD..."
    sudo mkdir -p "$MOUNT_OLD"
    sudo mount "$ROOT_PARTITION" "$MOUNT_OLD" || error "Failed to mount $ROOT_PARTITION for checking."
    mount_needed=true
  fi

  # Get used space percentage using awk
  used_percentage=$(df --output=pcent "$MOUNT_OLD" | tail -1 | awk '{print $1}' | tr -d '%')

  # Unmount if it was temporarily mounted
  if [[ "$mount_needed" == true ]]; then
    log "Unmounting from $MOUNT_OLD..."
    sudo umount "$MOUNT_OLD"
  fi

  # If used_percentage is empty, display an error
  if [[ -z "$used_percentage" ]]; then
    error "Failed to retrieve disk usage percentage for $ROOT_PARTITION."
  fi

  # Abort if more than 50% of the partition is used
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

# Install Btrfs tools
install_btrfs_tools() {
  log "Installing btrfs-progs..."
  sudo pacman -S --noconfirm btrfs-progs
}

# Resize the root partition filesystem to 50% of its original size
resize_filesystem() {
  log "Resizing $ROOT_PARTITION filesystem to 50% of its current size..."

  # Get total size in GB
  local total_size_gb
  total_size_gb=$(lsblk -b -n -o SIZE "$ROOT_PARTITION" | awk '{print $1/1024/1024/1024}')
  
  # Calculate 50% size
  local new_size_gb
  new_size_gb=$(echo "$total_size_gb / 2" | bc)

  log "Current filesystem size: ${total_size_gb}G, Resizing to: ${new_size_gb}G"

  # Resize the filesystem
  sudo resize2fs "$ROOT_PARTITION" "${new_size_gb}G" || error "Failed to resize filesystem."
}

# Run filesystem check
check_filesystem() {
  log "Checking filesystem on $ROOT_PARTITION..."
  sudo e2fsck -f "$ROOT_PARTITION"
} 

# Resize the root partition to 50% of its original size using fdisk
resize_partition() {
  log "Resizing $ROOT_PARTITION partition to 50% of its current size using fdisk..."

  # Get the actual disk device (e.g., /dev/mmcblk0 from /dev/mmcblk0p3)
  local disk_device
  disk_device=$(lsblk -no PKNAME "$ROOT_PARTITION" | head -n 1)
  disk_device="/dev/$disk_device"

  if [[ -z "$disk_device" || ! -b "$disk_device" ]]; then
    error "Failed to determine the disk device for $ROOT_PARTITION."
  fi

  # Extract partition number dynamically
  local partition_number
  partition_number=$(echo "$ROOT_PARTITION" | grep -o '[0-9]*$')

  if [[ -z "$partition_number" || ! "$partition_number" =~ ^[0-9]+$ ]]; then
    error "Failed to determine the partition number for $ROOT_PARTITION."
  fi

  # Get total partition size in GB
  local total_size_gb
  total_size_gb=$(lsblk -b -n -o SIZE "$ROOT_PARTITION" | awk '{print $1/1024/1024/1024}')

  # Calculate new partition size (50%)
  local new_size_gb
  new_size_gb=$(echo "$total_size_gb / 2" | bc)

  # Get start sector using `fdisk -l`
  local start_sector
  start_sector=$(sudo fdisk -l "$disk_device" | awk -v part="$ROOT_PARTITION" '$1 == part {print $2}')

  if [[ -z "$start_sector" ]]; then
    error "Failed to determine the start sector of $ROOT_PARTITION."
  fi

  log "Current partition size: ${total_size_gb}G, Resizing to: ${new_size_gb}G"
  log "Start sector: $start_sector"
  log "Partition number: $partition_number"

  # Run fdisk commands to resize the partition
  log "Resizing partition using fdisk..."
  sudo fdisk "$disk_device" <<EOF
d
$partition_number
n
$partition_number
$start_sector
+${new_size_gb}G
t
$partition_number
20  # Set partition type to Linux filesystem
w
EOF

  log "Partition resizing completed."

  # Verify the partition layout
  log "Verifying partition layout..."
  sudo fdisk -l "$disk_device"
}

# Create a new partition after the resized one
create_new_partition() {
  log "Creating a new partition after the resized root partition..."

  # Get the actual disk device (e.g., /dev/mmcblk0 from /dev/mmcblk0p3)
  local disk_device
  disk_device=$(lsblk -no PKNAME "$ROOT_PARTITION" | head -n 1)
  disk_device="/dev/$disk_device"

  if [[ -z "$disk_device" || ! -b "$disk_device" ]]; then
    error "Failed to determine the disk device for $ROOT_PARTITION."
  fi

  # Extract partition number dynamically
  local last_partition_number
  last_partition_number=$(sudo fdisk -l "$disk_device" | awk '/^\/dev/ {print $1}' | tail -n 1 | grep -o '[0-9]*$')

  if [[ -z "$last_partition_number" || ! "$last_partition_number" =~ ^[0-9]+$ ]]; then
    error "Failed to determine the last partition number on $disk_device."
  fi

  local new_partition_number=$((last_partition_number + 1))

  # Get the start sector of the next available space
  local last_partition_end
  last_partition_end=$(sudo fdisk -l "$disk_device" | awk '$1 ~ /'"$(basename "$ROOT_PARTITION")"'/ {print $3}')

  if [[ -z "$last_partition_end" ]]; then
    error "Failed to determine the end sector of the resized partition."
  fi

  local start_sector=$((last_partition_end + 1))

  log "Creating new partition $new_partition_number starting at sector $start_sector and using all available space."

  # Create the new partition using fdisk
  sudo fdisk "$disk_device" <<EOF
n
$new_partition_number
$start_sector

t
$new_partition_number
20  # Set partition type to Linux filesystem
w
EOF

  log "New partition $new_partition_number created successfully."

  # Verify the partition layout
  log "Verifying partition layout..."
  sudo fdisk -l "$disk_device"
}

# Format the newly created partition as Btrfs
format_partition_as_btrfs() {
  log "Formatting the new partition as Btrfs..."

  # Get the actual disk device (e.g., /dev/mmcblk0 from /dev/mmcblk0p3)
  local disk_device
  disk_device=$(lsblk -no PKNAME "$ROOT_PARTITION" | head -n 1)
  disk_device="/dev/$disk_device"

  if [[ -z "$disk_device" || ! -b "$disk_device" ]]; then
    error "Failed to determine the disk device for $ROOT_PARTITION."
  fi

  # Extract the latest partition number dynamically
  local new_partition
  new_partition=$(sudo fdisk -l "$disk_device" | awk '/^\/dev/ {print $1}' | tail -n 1)

  if [[ -z "$new_partition" || ! -b "$new_partition" ]]; then
    error "Failed to determine the newly created partition."
  fi

  log "New partition detected: $new_partition"

  # Format the partition as Btrfs
  log "Creating Btrfs filesystem on $new_partition..."
  sudo mkfs.btrfs -f "$new_partition" || error "Failed to format $new_partition as Btrfs."

  log "Btrfs filesystem successfully created on $new_partition."
}

# Create Btrfs subvolumes on the newly formatted partition
create_btrfs_subvolumes() {
  log "Creating Btrfs subvolumes..."

  # Get the disk device (e.g., /dev/mmcblk0)
  local disk_device
  disk_device="/dev/$(lsblk -no PKNAME "$ROOT_PARTITION")"

  if [[ -z "$disk_device" || ! -b "$disk_device" ]]; then
    error "Failed to determine the disk device for $ROOT_PARTITION."
  fi

  # Get the last created partition (newest one)
  local new_partition
  new_partition=$(sudo fdisk -l "$disk_device" | awk '/Linux filesystem/ {print $1}' | tail -n 1)

  if [[ -z "$new_partition" || ! -b "$new_partition" ]]; then
    error "Failed to determine the newly created Btrfs partition."
  fi

  log "New Btrfs partition detected: $new_partition"

  # Ensure the partition is formatted as Btrfs
  if ! sudo blkid "$new_partition" | grep -q "TYPE=\"btrfs\""; then
    error "$new_partition is not formatted as Btrfs!"
  fi

  # Mount the new partition
  sudo mount "$new_partition" "$MOUNT_NEW" || error "Failed to mount $new_partition."

  # Create Btrfs subvolumes
  for subvol in "@" "@home" "@pkg" "@snapshots"; do
    log "Creating subvolume: $subvol"
    sudo btrfs subvolume create "$MOUNT_NEW/$subvol" || error "Failed to create subvolume $subvol."
  done

  # Unmount the new partition
  sudo umount "$new_partition" || error "Failed to unmount $new_partition."  

  log "Btrfs subvolumes created successfully."
}



# === Main function ===
main() {
  process_args "$@"
  check_root
  create_mount_points
  check_free_space
  update_package_manager
  install_btrfs_tools
  #resize_filesystem
  #resize_partition
  check_filesystem
  #create_new_partition
  format_partition_as_btrfs
  create_btrfs_subvolumes
  log "Setup completed!"
}

# Execute main function
main "$@"

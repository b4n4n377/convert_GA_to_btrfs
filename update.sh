#!/bin/bash
# System Update Script with Btrfs Snapshot, Rollback, and Secure Boot Operations

# Function to check for recent updates
check_recent_updates() {

    # Display a message for checking recent updates
    echo -e "\e[31m---Checking for Recent Updates---\e[0m"

    # Create an array to store timestamps for the last 4 minutes
    timestamps=()

    # Generate timestamps for the last 4 minutes
    for ((i=3; i>=0; i--)); do
        timestamp=$(date -d "-$i minutes" +"[%Y-%m-%dT%H:%M")
        timestamps+=("$timestamp")
    done

    # Use grep to find lines in pacman.log that match the timestamps and contain 'installed' or 'upgraded'
    grep -Ff <(printf "%s\n" "${timestamps[@]}") /var/log/pacman.log | grep -E 'installed|upgraded'

    # Check the exit code of the previous command
    if [[ $? -eq 0 ]]; then
        echo "New updates have been installed within the last 2 minutes. Do you want to reboot? (y/n)"
        read answer
        if [[ "$answer" == "y" ]]; then
            echo "Rebooting in 3 seconds..."
            sleep 3
            reboot
        fi
    else
        echo "No updates were installed. Exiting in 3 seconds..."
        sleep 3
    fi
}

# Function for Snapshotting Filesystem
snapshot_filesystem() {
    # Display a message for snapshotting the filesystem
    echo -e "\e[31m---Snapshotting Filesystem---\e[0m"

    # Delete the old stable snapshot
    /usr/bin/btrfs subvolume delete /.snapshots/OLDSTABLE

    # Move the current stable snapshot to old stable
    /usr/bin/mv /.snapshots/STABLE /.snapshots/OLDSTABLE

    # Update the /etc/fstab file in old stable to replace STABLE with OLDSTABLE
    /usr/bin/sed -i 's/STABLE/OLDSTABLE/g' /.snapshots/OLDSTABLE/etc/fstab

    # Create a copy of the stable kernel and initramfs with old stable names
    /usr/bin/cp /boot/vmlinuz-linux-stable /boot/vmlinuz-linux-oldstable
    /usr/bin/cp /boot/initramfs-linux-stable.img /boot/initramfs-linux-oldstable.img

    # Create a new snapshot for the current stable system
    /usr/bin/btrfs subvolume snapshot / /.snapshots/STABLE

    # Update the /etc/fstab file in the new stable snapshot to replace TESTING with STABLE
    /usr/bin/sed -i 's/TESTING/STABLE/g' /.snapshots/STABLE/etc/fstab

    # Create a copy of the current kernel and initramfs with stable names
    /usr/bin/cp /boot/vmlinuz-linux /boot/vmlinuz-linux-stable
    /usr/bin/cp /boot/initramfs-linux.img /boot/initramfs-linux-stable.img
}

# Function for Updating System
update_system() {
    # Display a message for updating the system
    echo -e "\e[31m---Updating System---\e[0m"

    # Use reflector to update mirrorlist and select fast mirrors
    /usr/bin/reflector --verbose -l 5 -p https --sort rate --save /etc/pacman.d/mirrorlist

    # Update the system using pacman without asking for confirmation, and log the output
    /usr/bin/pacman -Syu --noconfirm | tee /tmp/pacman_update_log
}

# Function for Balancing Filesystem
balance_filesystem() {
    # Display a message for balancing the filesystem
    echo -e "\e[31m---Balancing Filesystem---\e[0m"

    # Start balancing the filesystem to optimize disk usage
    /usr/bin/btrfs balance start -dusage=5 /btrfs
}

# Main script
snapshot_filesystem
update_system
balance_filesystem
check_recent_updates

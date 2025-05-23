#!/usr/bin/env bash

# === Initial Setup and Error Handling ===
set -e
# ... (SCRIPT_DIR, TEMPLATE_DIR etc. as before) ...

# === Function Definitions ===
confirm() {
    # ... (confirm function as before) ...
}

# --- 0. Preamble and Critical Warning ---
# ... (Preamble and warning as before) ...
if ! confirm "Do you understand these warnings and accept full responsibility for proceeding?"; then
    echo "Installation aborted by user."
    exit 1
fi
echo "--------------------------------------------------------------------"

# --- 1. Gather Information Interactively ---
# ... (TARGET_DISK, NIXOS_USERNAME, GIT_USERNAME, GIT_USEREMAIL, PASSWORD_HASH, HOSTNAME collection as before) ...

# --- Define Partition Sizes and Names ---
EFI_SIZE_REQUESTED_MiB="512"  # Requested size for EFI in MiB
SWAP_SIZE_REQUESTED_GiB="16" # Requested size for Swap in GiB

EFI_PART_NAME="EFI"
ROOT_PART_NAME="ROOT_NIXOS"
SWAP_PART_NAME="SWAP"
DEFAULT_ROOT_FS_TYPE="ext4"

echo "--------------------------------------------------------------------"
echo "Configuration Summary (before disk operations):"
# ... (Display summary as before) ...
if ! confirm "Review the summary. Proceed with disk operations using these settings?"; then
    echo "Installation aborted by user."
    exit 1
fi
echo "--------------------------------------------------------------------"

# --- 2. Disk Partitioning, Formatting, and Mounting (Precise Calculation Method) ---
echo "Step 2: Starting disk partitioning, formatting, and mounting on $TARGET_DISK..."
echo "This will ERASE ALL DATA on $TARGET_DISK."
if ! confirm "FINAL WARNING: Proceed with partitioning $TARGET_DISK?"; then
    echo "Partitioning aborted by user."
    exit 1
fi

{ # Start of disk operations block
    echo "Wiping existing partition table on $TARGET_DISK..."
    sudo sgdisk --zap-all "$TARGET_DISK"
    sudo sgdisk --clear "$TARGET_DISK" # Create new GPT
    echo "Disk wiped and new GPT created."

    # Get disk information for calculations
    SECTOR_SIZE_BYTES=$(sudo blockdev --getss "$TARGET_DISK")
    if ! [[ "$SECTOR_SIZE_BYTES" =~ ^[0-9]+$ ]] || [ "$SECTOR_SIZE_BYTES" -le 0 ]; then
        echo "Error: Could not determine sector size for $TARGET_DISK. Assuming 512."
        SECTOR_SIZE_BYTES=512
    fi
    echo "Disk Sector Size: ${SECTOR_SIZE_BYTES} bytes"

    # Using sgdisk to get usable sector range, which accounts for GPT metadata
    # sgdisk --print prints to stderr, so redirect.
    # We need to capture "first usable sector" and "last usable sector".
    # Example output line: "First usable sector is 34, last usable sector is 85899342"
    disk_info=$(sudo sgdisk --print "$TARGET_DISK" 2>&1) # Capture stderr too
    FIRST_USABLE_SECTOR=$(echo "$disk_info" | awk '/^First usable sector is/{print $5}')
    LAST_USABLE_SECTOR=$(echo "$disk_info" | awk '/^Last usable sector is/{print $5}')

    if ! [[ "$FIRST_USABLE_SECTOR" =~ ^[0-9]+$ ]] || ! [[ "$LAST_USABLE_SECTOR" =~ ^[0-9]+$ ]]; then
        echo "Error: Could not parse usable sector range from sgdisk output for $TARGET_DISK."
        exit 1
    fi
    echo "First Usable Sector: $FIRST_USABLE_SECTOR, Last Usable Sector: $LAST_USABLE_SECTOR"
    USABLE_DISK_SECTORS=$((LAST_USABLE_SECTOR - FIRST_USABLE_SECTOR + 1))
    echo "Total Usable Sectors: $USABLE_DISK_SECTORS"


    # --- Create Partitions in sequence: EFI, then Root, then Swap ---

    # 1. EFI Partition (at the beginning)
    # Size in MiB, sgdisk handles conversion with 'M' suffix.
    # Start at the first usable sector.
    EFI_PART_START_SECTOR="$FIRST_USABLE_SECTOR"
    # Size is specified as +SizeSuffix (e.g., +512M)
    EFI_PART_SIZE_SGDISK="+${EFI_SIZE_REQUESTED_MiB}M"
    echo "Creating EFI partition (start: ${EFI_PART_START_SECTOR}, size: ${EFI_SIZE_REQUESTED_MiB}MiB)..."
    sudo sgdisk --new=1:${EFI_PART_START_SECTOR}:${EFI_PART_SIZE_SGDISK} --typecode=1:ef00 --change-name=1:"$EFI_PART_NAME" "$TARGET_DISK"
    # Get the actual end sector of the created EFI partition for the next calculation.
    # sgdisk aligns partitions, so actual end might differ slightly from simple calculation.
    # We use sgdisk --info to get the *actual* last sector of the created partition.
    PART1_LAST_SECTOR=$(sudo sgdisk --info=1 "$TARGET_DISK" | awk '/^Last sector:/{print $3; exit}')
    echo "EFI partition created as partition 1, ending at sector $PART1_LAST_SECTOR."
    sudo sgdisk -p "$TARGET_DISK"


    # 2. Root Partition (Ext4)
    # It starts immediately after the EFI partition.
    # Its size is (Total Usable Sectors) - (EFI Size in Sectors) - (Swap Size in Sectors).
    # Convert requested Swap size to sectors.
    SWAP_SIZE_BYTES_REQUESTED=$((SWAP_SIZE_REQUESTED_GiB * 1024 * 1024 * 1024))
    SWAP_SIZE_SECTORS_REQUESTED=$((SWAP_SIZE_BYTES_REQUESTED / SECTOR_SIZE_BYTES))

    # Calculate Root partition size in sectors.
    # Actual EFI size in sectors:
    PART1_FIRST_SECTOR=$(sudo sgdisk --info=1 "$TARGET_DISK" | awk '/^First sector:/{print $3; exit}')
    EFI_SIZE_SECTORS_ACTUAL=$((PART1_LAST_SECTOR - PART1_FIRST_SECTOR + 1))

    # Remaining usable sectors after EFI for Root and Swap
    SECTORS_REMAINING_FOR_ROOT_SWAP=$((LAST_USABLE_SECTOR - PART1_LAST_SECTOR))

    # Allocate SWAP_SIZE_SECTORS_REQUESTED for Swap, the rest for Root.
    # Ensure SWAP_SIZE_SECTORS_REQUESTED doesn't exceed remaining space.
    if [ "$SWAP_SIZE_SECTORS_REQUESTED" -ge "$SECTORS_REMAINING_FOR_ROOT_SWAP" ]; then
        echo "Error: Requested SWAP size is too large for the remaining disk space after EFI."
        echo "       Remaining sectors for Root & Swap: $SECTORS_REMAINING_FOR_ROOT_SWAP"
        echo "       Requested Swap sectors: $SWAP_SIZE_SECTORS_REQUESTED"
        exit 1
    fi
    ROOT_SIZE_SECTORS_CALCULATED=$((SECTORS_REMAINING_FOR_ROOT_SWAP - SWAP_SIZE_SECTORS_REQUESTED))

    if [ "$ROOT_SIZE_SECTORS_CALCULATED" -le 0 ]; then
        echo "Error: Not enough space for ROOT partition. Calculated Root sectors: $ROOT_SIZE_SECTORS_CALCULATED"
        exit 1
    fi

    ROOT_PART_START_SECTOR=$((PART1_LAST_SECTOR + 1))
    # Size for Root partition using +sectorsS (sgdisk takes 'S' or 's' for sectors)
    ROOT_PART_SIZE_SGDISK="+${ROOT_SIZE_SECTORS_CALCULATED}S"
    echo "Creating ROOT partition (start: $ROOT_PART_START_SECTOR, size: ${ROOT_SIZE_SECTORS_CALCULATED} sectors)..."
    sudo sgdisk --new=2:${ROOT_PART_START_SECTOR}:${ROOT_PART_SIZE_SGDISK} --typecode=2:8300 --change-name=2:"$ROOT_PART_NAME" "$TARGET_DISK"
    PART2_LAST_SECTOR=$(sudo sgdisk --info=2 "$TARGET_DISK" | awk '/^Last sector:/{print $3; exit}')
    echo "ROOT partition created as partition 2, ending at sector $PART2_LAST_SECTOR."
    sudo sgdisk -p "$TARGET_DISK"

    # 3. Swap Partition (in the space remaining at the end)
    SWAP_PART_START_SECTOR=$((PART2_LAST_SECTOR + 1))
    # End at the last usable sector of the disk.
    echo "Creating SWAP partition (start: $SWAP_PART_START_SECTOR, end: $LAST_USABLE_SECTOR)..."
    # Check if there's any space left for SWAP
    if [ "$SWAP_PART_START_SECTOR" -gt "$LAST_USABLE_SECTOR" ]; then
        echo "Warning: No space left for SWAP partition after creating ROOT. SWAP will be very small or not created."
        # Optionally, error out or create a minimal swap if possible.
        # For now, proceed, sgdisk might handle tiny partitions or error out.
    fi
    sudo sgdisk --new=3:${SWAP_PART_START_SECTOR}:${LAST_USABLE_SECTOR} --typecode=3:8200 --change-name=3:"$SWAP_PART_NAME" "$TARGET_DISK"
    echo "SWAP partition created as partition 3."

    echo "Final partition layout on $TARGET_DISK:"
    sudo sgdisk -v "$TARGET_DISK" # Verify disk integrity
    sudo sgdisk -p "$TARGET_DISK" # Print final layout

    echo "Informing kernel of partition table changes..."
    sudo partprobe "$TARGET_DISK" && sleep 3

    # Verify that partlabels are accessible (same as before)
    # ... (ls -l /dev/disk/by-partlabel/ and confirm prompt) ...
    echo "Verifying partition labels are accessible..."
    if [ ! -e "/dev/disk/by-partlabel/$EFI_PART_NAME" ] || \
       [ ! -e "/dev/disk/by-partlabel/$ROOT_PART_NAME" ] || \
       [ ! -e "/dev/disk/by-partlabel/$SWAP_PART_NAME" ]; then
        echo "Warning: Not all partition labels immediately accessible. Waiting a few seconds..."
        sleep 5 # Give udev more time
        if [ ! -e "/dev/disk/by-partlabel/$EFI_PART_NAME" ] || \
           [ ! -e "/dev/disk/by-partlabel/$ROOT_PART_NAME" ] || \
           [ ! -e "/dev/disk/by-partlabel/$SWAP_PART_NAME" ]; then
            echo "ERROR: Partition labels still not accessible under /dev/disk/by-partlabel/."
            echo "       Current labels found:"
            ls -l /dev/disk/by-partlabel/ || echo "(No labels found or ls error)"
            echo "       Please check partition creation and naming. Aborting."
            exit 1
        fi
    fi
    echo "Partition labels verified."


    echo "Formatting partitions using labels..."
    sudo mkfs.vfat -F 32 -n "$EFI_PART_NAME" "/dev/disk/by-partlabel/$EFI_PART_NAME"
    sudo mkfs.ext4 -L "$ROOT_PART_NAME" "/dev/disk/by-partlabel/$ROOT_PART_NAME"
    sudo mkswap -L "$SWAP_PART_NAME" "/dev/disk/by-partlabel/$SWAP_PART_NAME"
    echo "Partitions formatted."

    echo "Mounting filesystems to /mnt..."
    sudo mount -L "$ROOT_PART_NAME" /mnt
    sudo mkdir -p /mnt/boot
    sudo mount -L "$EFI_PART_NAME" /mnt/boot
    sudo swapon -L "$SWAP_PART_NAME"
    echo "Filesystems mounted."

    echo "Current mount status and block device layout:"
    df -h /mnt /mnt/boot
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DISK"

} || {
    echo "ERROR: A critical error occurred during disk operations."
    exit 1
}
echo "Disk operations completed successfully."
echo "--------------------------------------------------------------------"

# --- Steps 3, 4, 5 (Generate hardware-config, Flake/module files, nixos-install) as before ---
# ... (The rest of the script remains the same as the last full version provided) ...

echo "===================================================================="
echo "Script finished."
exit 0
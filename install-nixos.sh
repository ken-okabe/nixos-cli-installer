#!/usr/bin/env bash

# === Initial Setup and Error Handling ===
set -e # Exit immediately if a command exits with a non-zero status.

# Get the directory where the script is located to reference template files.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
USER_CONFIG_FILES_DIR="${SCRIPT_DIR}/templates/config" # For user-provided Zellij configs
TARGET_NIXOS_CONFIG_DIR="/mnt/etc/nixos"                # NixOS config on the target mount

# === Function Definitions ===
confirm() {
    # Prompts the user for a yes/no confirmation.
    # Usage: confirm "Your question"
    # Returns 0 (true for bash conditional) for yes, 1 (false for bash conditional) for no.
    while true; do
        # -r: do not allow backslashes to escape any characters
        # -p: display the prompt string before reading input
        read -r -p "$1 [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) # Match 'y', 'Y', 'yes', 'YES', 'Yes'
                return 0 # Indicates success (true in shell scripting conditional tests)
                ;;
            [nN][oO]|[nN]|"")  # Match 'n', 'N', 'no', 'NO', 'No', or an empty string (Enter key)
                return 1 # Indicates failure (false in shell scripting conditional tests)
                ;;
            *)
                # Invalid input, prompt again
                echo "Invalid input. Please enter 'y' or 'n'."
                ;;
        esac
    done
}

# --- 0. Preamble and Critical Warning ---
echo "===================================================================="
echo "NixOS Flake-based Installation Helper Script"
echo "===================================================================="
echo "WARNING: This script is designed to partition a disk, format it,"
echo "         and install NixOS. This will ERASE ALL DATA on the"
echo "         selected disk."
echo ""
echo "         Execute this script entirely AT YOUR OWN RISK."
echo "         No liability is assumed for any data loss or system damage."
echo ""
echo "         It is STRONGLY recommended to:"
echo "           1. Back up any important data."
echo "           2. Detach any unnecessary disks or media before proceeding."
echo "           3. Carefully verify the target disk when prompted."
echo "--------------------------------------------------------------------"
if ! confirm "Do you understand these warnings and accept full responsibility for proceeding?"; then
    echo "Installation aborted by user."
    exit 1
fi
echo "--------------------------------------------------------------------"

# --- 1. Gather Information Interactively ---
echo "Please provide the following information for the new NixOS installation:"

# 1.1. Target Disk Selection
echo ""
echo "Available block devices (physical disks, not partitions):"
lsblk -pno NAME,SIZE,MODEL # List block devices to help user identify the target.
echo ""
while true; do
    read -r -p "Enter the target disk for NixOS installation (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK
    if [[ -b "$TARGET_DISK" ]]; then # Check if it's a block device.
        if confirm "You have selected '$TARGET_DISK'. ALL DATA ON THIS DISK WILL BE ERASED! Are you absolutely sure?"; then
            break
        else
            echo "Target disk selection cancelled. Please enter a different disk or abort."
        fi
    else
        echo "Error: '$TARGET_DISK' is not a valid block device. Please try again."
    fi
done

# 1.2. Partitioning Constants
SWAP_SIZE_GB="16" # Fixed to 16GiB as per user request
DEFAULT_EFI_SIZE_MiB="512"  # Size for EFI in MiB

EFI_PART_NAME="EFI"         # Label for the EFI partition
SWAP_PART_NAME="SWAP"       # Label for the Swap partition
ROOT_PART_NAME="ROOT_NIXOS" # Label for the Root partition
DEFAULT_ROOT_FS_TYPE="ext4"

# 1.3. System Username
echo ""
read -r -p "Enter the desired username for the primary system user (e.g., ken): " NIXOS_USERNAME
while [[ -z "$NIXOS_USERNAME" ]]; do
    read -r -p "Username is required. Please enter a username: " NIXOS_USERNAME
done

# 1.4. Git User Information (distinct from system user)
echo ""
read -r -p "Enter your Git username (for commits, can be different from system user): " GIT_USERNAME
while [[ -z "$GIT_USERNAME" ]]; do
    read -r -p "Git username is required. Please enter one: " GIT_USERNAME
done
read -r -p "Enter your Git email address (for commits): " GIT_USEREMAIL
while [[ -z "$GIT_USEREMAIL" ]]; do
    read -r -p "Git email address is required. Please enter one: " GIT_USEREMAIL
done

# 1.5. Password Setup (using mkpasswd)
echo ""
echo "Next, set the password for the system user ('${NIXOS_USERNAME}') and the root account."
echo "You will be prompted to enter the password twice (input will not be displayed)."
pass1=""
pass2=""
while true; do
    read -r -s -p "Enter password: " pass1
    echo ""
    read -r -s -p "Retype password: " pass2
    echo ""
    if [[ "$pass1" == "$pass2" ]]; then
        if [[ -z "$pass1" ]]; then
            echo "Error: Password cannot be empty. Please try again."
        else
            break # Passwords match and are not empty.
        fi
    else
        echo "Error: Passwords do not match. Please try again."
    fi
done
# Generate password hash using mkpasswd (available in NixOS live env).
# The '-s' flag reads the password from stdin, which is more secure than command-line args.
PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 -s)
if [[ -z "$PASSWORD_HASH" || ! "$PASSWORD_HASH" == \$6\$* ]]; then # Basic check for $6$ hash format.
    echo "Error: Failed to generate password hash with mkpasswd. Ensure mkpasswd is available and working."
    exit 1
fi
unset pass1 # Clear plaintext password variables for security.
unset pass2
echo "Password hash generated successfully."

# 1.6. Hostname
echo ""
DEFAULT_HOSTNAME="nixos" # This should match the key in nixosConfigurations in flake.nix
read -r -p "Enter the system hostname (default: ${DEFAULT_HOSTNAME}): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME} # Use default if input is empty.

echo "--------------------------------------------------------------------"
echo "Configuration Summary:"
echo "  Target Disk:        $TARGET_DISK"
echo "  EFI Size:           ${DEFAULT_EFI_SIZE_MiB}MiB"
echo "  Swap Size:          ${SWAP_SIZE_GB}GiB"
echo "  Root Filesystem:    $DEFAULT_ROOT_FS_TYPE (on remaining space)"
echo "  System Username:    $NIXOS_USERNAME"
echo "  Git Username:       $GIT_USERNAME"
echo "  Git Email:          $GIT_USEREMAIL"
echo "  Hostname:           $HOSTNAME"
echo "  Password Hash:      (Generated, not displayed for security)"
echo ""
if ! confirm "Review the summary above. Do you want to proceed with these settings?"; then
    echo "Installation aborted by user."
    exit 1
fi
echo "--------------------------------------------------------------------"

# --- 2. Disk Partitioning, Formatting, and Mounting (Precise Calculation Method as per final user spec) ---
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

    disk_info_sgdisk=$(sudo sgdisk --print "$TARGET_DISK" 2>&1)
    FIRST_USABLE_SECTOR=$(echo "$disk_info_sgdisk" | awk '/^First usable sector is/{print $5}')
    LAST_USABLE_SECTOR=$(echo "$disk_info_sgdisk" | awk '/^Last usable sector is/{print $5}')

    if ! [[ "$FIRST_USABLE_SECTOR" =~ ^[0-9]+$ ]] || ! [[ "$LAST_USABLE_SECTOR" =~ ^[0-9]+$ ]]; then
        echo "Error: Could not parse usable sector range from sgdisk output for $TARGET_DISK."
        sgdisk_output_for_debug=$(sudo sgdisk --print "$TARGET_DISK" 2>&1)
        echo "sgdisk output was: $sgdisk_output_for_debug"
        exit 1
    fi
    echo "First Usable Sector: $FIRST_USABLE_SECTOR, Last Usable Sector: $LAST_USABLE_SECTOR"

    # --- Create Partitions in sequence: EFI (1), then Root (2), then Swap (3) ---

    # 1. EFI Partition
    EFI_PART_START_SECTOR="$FIRST_USABLE_SECTOR"
    EFI_PART_SIZE_SGDISK="+${DEFAULT_EFI_SIZE_MiB}M"
    echo "Creating EFI partition (number 1, start: ${EFI_PART_START_SECTOR}, size: ${DEFAULT_EFI_SIZE_MiB}MiB)..."
    sudo sgdisk --new=1:${EFI_PART_START_SECTOR}:${EFI_PART_SIZE_SGDISK} --typecode=1:ef00 --change-name=1:"$EFI_PART_NAME" "$TARGET_DISK"
    PART1_LAST_SECTOR=$(sudo sgdisk --info=1 "$TARGET_DISK" | awk '/^Last sector:/{print $3; exit}')
    echo "EFI partition created, ending at sector $PART1_LAST_SECTOR."
    sudo sgdisk -p "$TARGET_DISK"

    # 2. Root Partition
    # Calculate size to leave for SWAP at the end.
    SWAP_SIZE_BYTES_REQUESTED=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
    SWAP_SIZE_SECTORS_REQUESTED=$((SWAP_SIZE_BYTES_REQUESTED / SECTOR_SIZE_BYTES))

    ROOT_PART_START_SECTOR=$((PART1_LAST_SECTOR + 1))
    # Ensure Root ends such that SWAP_SIZE_SECTORS_REQUESTED are left before LAST_USABLE_SECTOR.
    ROOT_PART_END_SECTOR=$((LAST_USABLE_SECTOR - SWAP_SIZE_SECTORS_REQUESTED))

    if [ "$ROOT_PART_END_SECTOR" -le "$ROOT_PART_START_SECTOR" ]; then
        echo "Error: Not enough space for ROOT partition after reserving for EFI and SWAP."
        exit 1
    fi
    echo "Creating ROOT partition (number 2, start: $ROOT_PART_START_SECTOR, end: $ROOT_PART_END_SECTOR)..."
    sudo sgdisk --new=2:${ROOT_PART_START_SECTOR}:${ROOT_PART_END_SECTOR} --typecode=2:8300 --change-name=2:"$ROOT_PART_NAME" "$TARGET_DISK"
    PART2_LAST_SECTOR=$(sudo sgdisk --info=2 "$TARGET_DISK" | awk '/^Last sector:/{print $3; exit}')
    echo "ROOT partition created, ending at sector $PART2_LAST_SECTOR."
    sudo sgdisk -p "$TARGET_DISK"

    # 3. Swap Partition (in the remaining space at the end)
    SWAP_PART_START_SECTOR=$((PART2_LAST_SECTOR + 1))
    echo "Creating SWAP partition (number 3, start: $SWAP_PART_START_SECTOR, end: $LAST_USABLE_SECTOR)..."
    if [ "$SWAP_PART_START_SECTOR" -gt "$LAST_USABLE_SECTOR" ]; then
        echo "Warning: No significant space left for SWAP partition. It might be very small or fail to create."
        # If this happens, the calculation for ROOT_PART_END_SECTOR was too aggressive or disk too small.
    fi
    sudo sgdisk --new=3:${SWAP_PART_START_SECTOR}:${LAST_USABLE_SECTOR} --typecode=3:8200 --change-name=3:"$SWAP_PART_NAME" "$TARGET_DISK"
    echo "SWAP partition created."

    echo "Final partition layout on $TARGET_DISK:"
    sudo sgdisk -v "$TARGET_DISK" # Verify disk integrity
    sudo sgdisk -p "$TARGET_DISK" # Print final layout

    echo "Informing kernel of partition table changes..."
    sudo partprobe "$TARGET_DISK" && sleep 3

    # Verify that partlabels are accessible
    echo "Verifying partition labels are accessible..."
    # Increased robustness for label verification
    label_wait_count=0
    while true; do
        if [ -e "/dev/disk/by-partlabel/$EFI_PART_NAME" ] && \
           [ -e "/dev/disk/by-partlabel/$ROOT_PART_NAME" ] && \
           [ -e "/dev/disk/by-partlabel/$SWAP_PART_NAME" ]; then
            echo "All partition labels successfully verified."
            break
        fi
        label_wait_count=$((label_wait_count + 1))
        if [ "$label_wait_count" -gt 5 ]; then # Wait up to 5*2 = 10 seconds
            echo "ERROR: Timeout waiting for partition labels to appear under /dev/disk/by-partlabel/."
            ls -l /dev/disk/by-partlabel/ || echo "(No labels found or ls error)"
            echo "       Please check partition creation and naming. Aborting."
            exit 1
        fi
        echo "Waiting for labels to appear (attempt ${label_wait_count})..."
        sleep 2
    done

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

# --- 3. Generate hardware-configuration.nix ---
echo "Step 3: Generating NixOS hardware configuration (hardware-configuration.nix)..."
sudo nixos-generate-config --root /mnt || {
    echo "ERROR: nixos-generate-config failed."
    exit 1
}
echo "hardware-configuration.nix generated at ${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix."
if [ -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix" ]; then
    echo "Note: A base configuration.nix was also generated by nixos-generate-config."
    echo "      This base configuration.nix will NOT be used by our Flake if not listed in flake.nix's modules."
fi
echo "--------------------------------------------------------------------"

# --- 4. Generate Flake and Custom Module Files from Templates ---
echo "Step 4: Generating Flake and custom NixOS module files..."
sudo mkdir -p "${TARGET_NIXOS_CONFIG_DIR}"

generate_from_template() {
    local template_file_basename="$1"
    local output_file_basename="$2"
    local template_path="${TEMPLATE_DIR}/${template_file_basename}"
    local output_path="${TARGET_NIXOS_CONFIG_DIR}/${output_file_basename}"

    if [[ ! -f "$template_path" ]]; then
        echo "ERROR: Template file not found: $template_path"
        return 1
    fi

    local sed_script=""
    sed_script+="-e \"s|__NIXOS_USERNAME__|${NIXOS_USERNAME}|g\" "
    sed_script+="-e \"s|__PASSWORD_HASH__|${PASSWORD_HASH}|g\" " # Ensure hash special characters are handled by sed if not using |
    sed_script+="-e \"s|__GIT_USERNAME__|${GIT_USERNAME}|g\" "
    sed_script+="-e \"s|__GIT_USEREMAIL__|${GIT_USEREMAIL}|g\" "
    sed_script+="-e \"s|__HOSTNAME__|${HOSTNAME}|g\" "
    sed_script+="-e \"s|__TARGET_DISK_FOR_GRUB__|${TARGET_DISK}|g\" "

    local temp_output
    temp_output=$(mktemp)

    # Use printf to handle potential special characters in PASSWORD_HASH for sed
    # This is complex. A simpler sed might work if hash doesn't contain sed delimiters.
    # For now, assuming simple sed with | delimiter (as in flake.nix template) is okay
    # if PASSWORD_HASH doesn't contain |. If it does, this needs more robust escaping.
    # A safer way: use awk or perl for templating, or pass vars as env vars to a nix expression.
    # Given the context, let's keep sed but be mindful.
    # The hash usually contains '$', which is fine. If it contains '/', then '|' as delimiter is good.

    if command sudo sed "${sed_script}" "${template_path}" > "${temp_output}"; then
        if sudo mv "$temp_output" "$output_path"; then
            echo "${output_file_basename} generated successfully at ${output_path}."
            sudo chmod 644 "$output_path"
        else
            echo "ERROR: Failed to move temporary file to ${output_path}."
            rm -f "$temp_output"
            return 1
        fi
    else
        echo "ERROR: sed command failed for generating ${output_file_basename} from ${template_file_basename}."
        echo "       Used sed script: sed ${sed_script} ${template_path}"
        rm -f "$temp_output"
        return 1
    fi
    return 0
}

declare -a module_templates=(
    "flake.nix.template:flake.nix"
    "system-settings.nix.template:system-settings.nix"
    "users.nix.template:users.nix"
    "system-packages.nix.template:system-packages.nix"
    "extra-apps.nix.template:extra-apps.nix"
    "gnome-desktop.nix.template:gnome-desktop.nix"
    "ime-and-fonts.nix.template:ime-and-fonts.nix"
    "sound.nix.template:sound.nix"
    "networking.nix.template:networking.nix"
    "bluetooth.nix.template:bluetooth.nix"
    "virtualbox-guest.nix.template:virtualbox-guest.nix"
    "system-customizations.nix.template:system-customizations.nix"
    "xremap.nix.template:xremap.nix"
    "bootloader.nix.template:bootloader.nix"
    "home-manager-user.nix.template:home-manager-user.nix"
)

for item in "${module_templates[@]}"; do
    IFS=":" read -r template_name output_name <<< "$item"
    if ! generate_from_template "$template_name" "$output_name"; then
        echo "ERROR: Failed to generate ${output_name}. Aborting installation."
        exit 1
    fi
done

echo "Copying user-provided configuration files (for Zellij)..."
if [[ -d "$USER_CONFIG_FILES_DIR" ]]; then
    for user_cfg_file in key-bindings.kdl layout-file.kdl; do
        if [[ -f "${USER_CONFIG_FILES_DIR}/${user_cfg_file}" ]]; then
            if sudo cp "${USER_CONFIG_FILES_DIR}/${user_cfg_file}" "${TARGET_NIXOS_CONFIG_DIR}/${user_cfg_file}"; then
                echo "${user_cfg_file} copied successfully to ${TARGET_NIXOS_CONFIG_DIR}/."
            else
                echo "WARNING: Failed to copy ${user_cfg_file} to ${TARGET_NIXOS_CONFIG_DIR}/."
            fi
        else
            echo "WARNING: User config file not found: ${USER_CONFIG_FILES_DIR}/${user_cfg_file}"
        fi
    done
else
    echo "WARNING: User config file directory ($USER_CONFIG_FILES_DIR) not found. Zellij configs may be missing."
fi

echo "All NixOS configuration files generated and placed in ${TARGET_NIXOS_CONFIG_DIR}/."
echo "--------------------------------------------------------------------"

# --- 5. Install NixOS ---
echo "Step 5: Installing NixOS using the Flake configuration..."
echo "This process will take a significant amount of time. Please be patient."
echo "You will see a lot of build output."
echo ""
if confirm "Proceed with NixOS installation?"; then
    echo "Starting nixos-install. This may take a while..."
    if sudo nixos-install --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"; then
        echo ""
        echo "--------------------------------------------------------------------"
        echo "NixOS installation completed successfully!"
        echo "You can now reboot your system."
        echo "To reboot, run: sudo reboot"
        echo "--------------------------------------------------------------------"
    else
        echo "ERROR: nixos-install failed. Please check the output above for errors."
        echo "The system filesystems are still mounted at /mnt."
        echo "You can investigate files in ${TARGET_NIXOS_CONFIG_DIR} or try installation steps again."
        exit 1
    fi
else
    echo "Installation aborted by user before final nixos-install step."
    echo "Filesystems are still mounted at /mnt. You can inspect or modify files in ${TARGET_NIXOS_CONFIG_DIR}"
    echo "and then run 'sudo nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}' manually if desired."
fi

echo "===================================================================="
echo "Script finished."
exit 0
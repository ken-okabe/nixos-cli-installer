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

# --- 2. Disk Partitioning, Formatting, and Mounting (Using parted, EFI -> Root -> Swap order) ---
echo "Step 2: Starting disk partitioning, formatting, and mounting on $TARGET_DISK..."
echo "This will ERASE ALL DATA on $TARGET_DISK."
if ! confirm "FINAL WARNING: Proceed with partitioning $TARGET_DISK with parted?"; then
    echo "Partitioning aborted by user."
    exit 1
fi

{ # Start of disk operations block
    echo "Creating new GPT partition table on $TARGET_DISK..."
    sudo parted --script "$TARGET_DISK" mklabel gpt
    echo "GPT label created."

    # Get total disk size in MiB for calculations
    TOTAL_DISK_MiB_FOR_PARTED_FLOAT=$(sudo parted --script "$TARGET_DISK" unit MiB print | awk '/^Disk \/dev\// {gsub(/MiB/,""); print $3}')
    if ! [[ "$TOTAL_DISK_MiB_FOR_PARTED_FLOAT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: Could not determine total disk size in MiB for $TARGET_DISK."
        exit 1
    fi
    TOTAL_DISK_MiB_FOR_PARTED_INT=$(printf "%.0f" "$TOTAL_DISK_MiB_FOR_PARTED_FLOAT") # Round to nearest integer for bash calculations
    echo "Total disk size (for parted calculations): ${TOTAL_DISK_MiB_FOR_PARTED_INT}MiB"

    # Convert SWAP GiB to MiB for parted calculations
    SWAP_SIZE_REQUESTED_MiB_INT=$((SWAP_SIZE_GB * 1024))

    # 1. Create EFI Partition (physical first)
    EFI_START_OFFSET_MiB="1" # Standard starting offset for alignment
    EFI_END_OFFSET_MiB="$((EFI_START_OFFSET_MiB + DEFAULT_EFI_SIZE_MiB))"
    echo "Creating EFI partition (from ${EFI_START_OFFSET_MiB}MiB to ${EFI_END_OFFSET_MiB}MiB)..."
    sudo parted --script "$TARGET_DISK" unit MiB mkpart "$EFI_PART_NAME" fat32 "$EFI_START_OFFSET_MiB" "$EFI_END_OFFSET_MiB"
    sudo parted --script "$TARGET_DISK" set 1 esp on # Set ESP flag (boot flag for GPT)
    EFI_DEVICE_NODE="${TARGET_DISK}1" # Kernel will likely name this sda1, etc.
    echo "EFI partition created as ${EFI_DEVICE_NODE}."

    # 2. Root Partition (physical second)
    ROOT_START_OFFSET_MiB="$EFI_END_OFFSET_MiB"
    # Calculate where Root should end to leave space for Swap
    ROOT_END_OFFSET_MiB="$((TOTAL_DISK_MiB_FOR_PARTED_INT - SWAP_SIZE_REQUESTED_MiB_INT))"
    if [ "$ROOT_START_OFFSET_MiB" -ge "$ROOT_END_OFFSET_MiB" ]; then # Use integer comparison
        echo "Error: Calculated space for ROOT partition is invalid or too small."
        echo "       EFI ends at ${EFI_END_OFFSET_MiB}MiB, Swap needs ${SWAP_SIZE_REQUESTED_MiB_INT}MiB, Total ${TOTAL_DISK_MiB_FOR_PARTED_INT}MiB."
        exit 1
    fi
    echo "Creating ROOT partition (from ${ROOT_START_OFFSET_MiB}MiB to ${ROOT_END_OFFSET_MiB}MiB)..."
    sudo parted --script "$TARGET_DISK" unit MiB mkpart "$ROOT_PART_NAME" "$DEFAULT_ROOT_FS_TYPE" "$ROOT_START_OFFSET_MiB" "$ROOT_END_OFFSET_MiB"
    ROOT_DEVICE_NODE="${TARGET_DISK}2" # Kernel will likely name this sda2, etc.
    echo "ROOT partition created as ${ROOT_DEVICE_NODE}."

    # 3. Swap Partition (physical third, in the remaining space at the end)
    SWAP_START_OFFSET_MiB="$ROOT_END_OFFSET_MiB"
    # End at 100% of disk (parted handles this for the last partition)
    echo "Creating SWAP partition (from ${SWAP_START_OFFSET_MiB}MiB to 100%)..."
    sudo parted --script "$TARGET_DISK" unit MiB mkpart "$SWAP_PART_NAME" linux-swap "$SWAP_START_OFFSET_MiB" 100%
    SWAP_DEVICE_NODE="${TARGET_DISK}3" # Kernel will likely name this sda3, etc.
    echo "SWAP partition created as ${SWAP_DEVICE_NODE}."

    echo "Final partition layout on $TARGET_DISK (using parted print):"
    sudo parted --script "$TARGET_DISK" print
    echo "Informing kernel of partition table changes..."
    sudo partprobe "$TARGET_DISK" && sleep 3 # Give kernel time to recognize changes.

    echo "Formatting partitions..."
    # We will use the device nodes derived from partition order for formatting,
    # and set filesystem labels with mkfs.
    sudo mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"
    sudo mkfs."$DEFAULT_ROOT_FS_TYPE" -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE"
    sudo mkswap -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE"
    echo "Partitions formatted."

    echo "Mounting filesystems..."
    # Mount by label, which were set during mkfs.
    sudo mount -L "$ROOT_PART_NAME" /mnt
    sudo mkdir -p /mnt/boot
    # For EFI, some prefer mounting by device or UUID, but label should also work if set by mkfs.vfat.
    # If mkfs.vfat -n doesn't create a /dev/disk/by-label entry reliably, use $EFI_DEVICE_NODE.
    sudo mount "$EFI_DEVICE_NODE" /mnt/boot
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
    # Using | as sed delimiter to avoid issues if paths/hashes contain /
    sed_script+="-e \"s|__NIXOS_USERNAME__|${NIXOS_USERNAME}|g\" "
    # For PASSWORD_HASH, ensure it doesn't contain the sed delimiter itself, or escape it.
    # Since mkpasswd $6$ format doesn't usually contain '|', this should be safe.
    sed_script+="-e \"s|__PASSWORD_HASH__|${PASSWORD_HASH}|g\" "
    sed_script+="-e \"s|__GIT_USERNAME__|${GIT_USERNAME}|g\" "
    sed_script+="-e \"s|__GIT_USEREMAIL__|${GIT_USEREMAIL}|g\" "
    sed_script+="-e \"s|__HOSTNAME__|${HOSTNAME}|g\" "
    sed_script+="-e \"s|__TARGET_DISK_FOR_GRUB__|${TARGET_DISK}|g\" "

    local temp_output
    temp_output=$(mktemp)

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
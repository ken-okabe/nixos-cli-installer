#!/usr/bin/env bash

# --- Initial Setup and Error Handling ---
set -e # Exit immediately if a command exits with a non-zero status.
# Get the directory where the script is located.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
USER_CONFIG_FILES_DIR="${SCRIPT_DIR}/templates/config" # For user-provided Zellij configs
TARGET_NIXOS_CONFIG_DIR="/mnt/etc/nixos"

# --- Function Definitions ---
# Confirm function for sensitive operations (default N)
confirm_sensitive() {
    while true; do
        read -r -p "$1 [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY])
                return 0 # Yes
                ;;
            [nN][oO]|[nN]|"") # Default to No if Enter is pressed
                return 1 # No
                ;;
            *)
                echo "Invalid input. Please enter 'y' or 'n'."
                ;;
        esac
    done
}

# Confirm function for less sensitive operations (default Y)
confirm_default_yes() {
    while true; do
        read -r -p "$1 [Y/n]: " response
        case "$response" in
            [yY][eE][sS]|[yY]|"") # Default to Yes if Enter is pressed
                return 0 # Yes
                ;;
            [nN][oO]|[nN])
                return 1 # No
                ;;
            *)
                echo "Invalid input. Please enter 'y' or 'n'."
                ;;
        esac
    done
}

# --- 0. Preamble and Warning ---
echo "===================================================================="
echo "NixOS Flake-based Installation Helper Script"
echo "===================================================================="
echo "WARNING: This script may erase all data on the selected disk"
echo "         and will install NixOS."
echo "         Execute this script entirely at your own risk."
echo "         It is STRONGLY recommended to detach any unnecessary disks"
echo "         or media before proceeding."
if ! confirm_sensitive "Do you understand the risks and wish to continue?"; then # Use sensitive confirm
    echo "Installation aborted by user."
    exit 1
fi
echo "--------------------------------------------------------------------"

# --- 1. Gather Information Interactively ---
echo "Please provide the following information:"

# 1.1. Target Disk
echo "Available block devices (physical disks, not partitions):"
lsblk -pno NAME,SIZE,MODEL # List block devices
echo ""
while true; do
    read -r -p "Enter the target disk for NixOS installation (e.g., /dev/sda): " TARGET_DISK
    if [[ -b "$TARGET_DISK" ]]; then
        if confirm_sensitive "Install NixOS on '$TARGET_DISK'? ALL DATA ON THIS DISK WILL BE ERASED!"; then # Use sensitive confirm
            break
        fi
    else
        echo "Error: '$TARGET_DISK' is not a valid block device. Please try again."
    fi
done

# 1.2. Swap Size (GB)
SWAP_SIZE_GB="16" # Fixed to 16GB as per user request

# Other partitioning constants
DEFAULT_EFI_SIZE="512M"
EFI_PART_NAME="EFI"
SWAP_PART_NAME="SWAP"
ROOT_PART_NAME="ROOT_NIXOS"
DEFAULT_ROOT_FS_TYPE="ext4"

# 1.3. System Username
read -r -p "Enter the desired username for the primary system user (e.g., ken): " NIXOS_USERNAME
while [[ -z "$NIXOS_USERNAME" ]]; do
    read -r -p "Username is required. Please enter a username: " NIXOS_USERNAME
done

# 1.4. Git User Information (separate from system user)
read -r -p "Enter your Git username (for commits): " GIT_USERNAME
while [[ -z "$GIT_USERNAME" ]]; do
    read -r -p "Git username is required. Please enter one: " GIT_USERNAME
done
read -r -p "Enter your Git email address (for commits): " GIT_USEREMAIL
while [[ -z "$GIT_USEREMAIL" ]]; do
    read -r -p "Git email address is required. Please enter one: " GIT_USEREMAIL
done

# 1.5. Password Setup (using mkpasswd)
echo ""
echo "Next, you will set the password for the system user ('${NIXOS_USERNAME}') and root."
echo "You will be prompted to enter the password twice (input will not be shown)."
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
            break
        fi
    else
        echo "Error: Passwords do not match. Please try again."
    fi
done
# Generate password hash using mkpasswd (available in NixOS live env)
PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 -s)
if [[ -z "$PASSWORD_HASH" || ! "$PASSWORD_HASH" == \$6\$* ]]; then
    echo "Error: Failed to generate password hash with mkpasswd. Ensure mkpasswd is available and working."
    exit 1
fi
unset pass1 # Clear plaintext password variables for security
unset pass2
echo "Password hash generated successfully."

# 1.6. Hostname
DEFAULT_HOSTNAME="nixos" # This should match the key in nixosConfigurations in flake.nix
read -r -p "Enter the system hostname (default: ${DEFAULT_HOSTNAME}): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

echo "--------------------------------------------------------------------"
echo "Configuration Summary:"
echo "  Target Disk:        $TARGET_DISK"
echo "  Swap Size:          ${SWAP_SIZE_GB}GB"
echo "  System Username:    $NIXOS_USERNAME"
echo "  Git Username:       $GIT_USERNAME"
echo "  Git Email:          $GIT_USEREMAIL"
echo "  Hostname:           $HOSTNAME"
echo "  Password Hash:      (Generated, not displayed)"
if ! confirm_default_yes "Proceed with installation using these settings?"; then # Use default_yes confirm
    echo "Installation aborted by user."
    exit 1
fi
echo "--------------------------------------------------------------------"

# --- 2. Disk Partitioning, Formatting, and Mounting ---
echo "Step 2: Starting disk partitioning, formatting, and mounting on $TARGET_DISK..."
{
    echo "Wiping disk $TARGET_DISK..."
    sudo sgdisk --zap-all "$TARGET_DISK"
    sudo sgdisk --clear "$TARGET_DISK"

    echo "Creating EFI partition (512MiB)..."
    sudo sgdisk --new=1:0:+"$DEFAULT_EFI_SIZE" --typecode=1:ef00 --change-name=1:"$EFI_PART_NAME" "$TARGET_DISK"

    echo "Creating SWAP partition (${SWAP_SIZE_GB}GiB at the end of the disk)..."
    sudo sgdisk --new=3:0:-"${SWAP_SIZE_GB}G" --typecode=3:8200 --change-name=3:"$SWAP_PART_NAME" "$TARGET_DISK"

    echo "Creating ROOT partition (ext4, remaining space)..."
    sudo sgdisk --largest-new=2 --typecode=2:8300 --change-name=2:"$ROOT_PART_NAME" "$TARGET_DISK"

    echo "Probing partitions to inform kernel..."
    sudo partprobe "$TARGET_DISK" && sleep 3

    echo "Formatting partitions..."
    sudo mkfs.vfat -F 32 -n "$EFI_PART_NAME" "/dev/disk/by-partlabel/$EFI_PART_NAME"
    sudo mkswap -L "$SWAP_PART_NAME" "/dev/disk/by-partlabel/$SWAP_PART_NAME"
    sudo mkfs."$DEFAULT_ROOT_FS_TYPE" -L "$ROOT_PART_NAME" "/dev/disk/by-partlabel/$ROOT_PART_NAME"

    echo "Mounting filesystems to /mnt..."
    sudo mount "/dev/disk/by-partlabel/$ROOT_PART_NAME" /mnt
    sudo mkdir -p /mnt/boot
    sudo mount "/dev/disk/by-partlabel/$EFI_PART_NAME" /mnt/boot
    sudo swapon "/dev/disk/by-partlabel/$SWAP_PART_NAME"
} || {
    echo "ERROR: An error occurred during disk operations. Please check messages above."
    exit 1
}
echo "Disk operations completed successfully."
echo "--------------------------------------------------------------------"

# --- 3. Generate Basic NixOS Configuration Files ---
echo "Step 3: Generating hardware-configuration.nix for the new system..."
sudo nixos-generate-config --root /mnt || {
    echo "ERROR: nixos-generate-config failed."
    exit 1
}
echo "hardware-configuration.nix generated at ${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix."
if [ -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix" ]; then
    echo "Note: A base configuration.nix was also generated by nixos-generate-config."
    echo "       This base configuration.nix will NOT be used by the Flake if not listed in flake.nix's modules."
    echo "       Our setup uses custom modules instead."
fi
echo "--------------------------------------------------------------------"

# --- 4. Generate Flake and Custom Module Files from Templates ---
echo "Step 4: Generating Flake and custom module files from templates..."
sudo mkdir -p "${TARGET_NIXOS_CONFIG_DIR}"

# Function to generate a config file from a template
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
    # Ensure placeholders are unique enough not to clash with actual Nix code.
    sed_script+="-e \"s|__NIXOS_USERNAME__|${NIXOS_USERNAME}|g\" "
    sed_script+="-e \"s|__PASSWORD_HASH__|${PASSWORD_HASH}|g\" "
    sed_script+="-e \"s|__GIT_USERNAME__|${GIT_USERNAME}|g\" "
    sed_script+="-e \"s|__GIT_USEREMAIL__|${GIT_USEREMAIL}|g\" "
    sed_script+="-e \"s|__HOSTNAME__|${HOSTNAME}|g\" "
    sed_script+="-e \"s|__TARGET_DISK_FOR_GRUB__|${TARGET_DISK}|g\" "

    local temp_output
    temp_output=$(mktemp)

    if eval "sed ${sed_script} \"${template_path}\" > \"${temp_output}\""; then
        if sudo mv "$temp_output" "$output_path"; then
            echo "${output_file_basename} generated successfully at ${output_path}."
            sudo chmod 644 "$output_path"
        else
            echo "ERROR: Failed to move temporary file to ${output_path}."
            rm -f "$temp_output"
            return 1
        fi
    else
        echo "ERROR: sed command failed for ${template_file_basename}."
        rm -f "$temp_output"
        return 1
    fi
    return 0
}

# List of templates and their output names (ensure these match your file structure)
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

# Generate each module file from its template
for item in "${module_templates[@]}"; do
    IFS=":" read -r template_name output_name <<< "$item"
    if ! generate_from_template "$template_name" "$output_name"; then
        echo "Failed to generate ${output_name}. Aborting installation."
        # Consider cleanup steps here if needed (e.g., umount)
        exit 1
    fi
done

# Copy user-provided Zellij config files (from templates/config/ to /mnt/etc/nixos/)
# home-manager-user.nix will reference them as ./key-bindings.kdl etc.
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
if confirm_default_yes "Proceed with NixOS installation?"; then # Use default_yes confirm
    echo "Starting nixos-install. Output will be verbose..."
    # Use --no-root-passwd because rootHashedPassword is set in users.nix
    if sudo nixos-install --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"; then
        echo ""
        echo "--------------------------------------------------------------------"
        echo "NixOS installation completed successfully!"
        echo "You can now reboot your system."
        echo "Run: sudo reboot"
        echo "--------------------------------------------------------------------"
    else
        echo "ERROR: nixos-install failed. Please check the output above for errors."
        echo "The system filesystems are still mounted at /mnt."
        echo "You can investigate files in ${TARGET_NIXOS_CONFIG_DIR} or try installation steps again."
        exit 1
    fi
else
    echo "Installation aborted by user."
    echo "Filesystems are still mounted at /mnt. You can inspect or modify files in ${TARGET_NIXOS_CONFIG_DIR}"
    echo "and then run 'sudo nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}' manually if desired."
fi

echo "===================================================================="
exit 0
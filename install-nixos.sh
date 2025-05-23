#!/usr/bin/env bash

# === Initial Setup and Error Handling ===
set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for extreme debugging (prints every command executed)

# Get the directory where the script is located to reference template files.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
USER_CONFIG_FILES_DIR="${SCRIPT_DIR}/templates/config" # For user-provided Zellij configs
TARGET_NIXOS_CONFIG_DIR="/mnt/etc/nixos"                # NixOS config on the target mount

# === Function Definitions ===
# Usage: confirm "Your question" DEFAULT_RESPONSE_CHAR (Y or N)
# Prompts the user with "Your question [Y/n]: " or "Your question [y/N]: ".
# Returns 0 (Bash true) if the user confirms (enters 'y', 'yes', or presses Enter if default is 'Y').
# If the user declines (enters 'n', 'no', or presses Enter if default is 'N'),
# it re-prompts indefinitely.
# The user can abort the script at any time by pressing Ctrl+C.
confirm() {
    local question="$1"
    local default_response_char="$2" # Expected to be "Y" or "N"
    local prompt_display=""

    if [[ "$default_response_char" == "Y" ]]; then
        prompt_display="[Y/n]"
    elif [[ "$default_response_char" == "N" ]]; then
        prompt_display="[y/N]"
    else
        # This indicates a script developer error in calling this function.
        echo "DEVELOPER ERROR: confirm function called with invalid default_response_char: '$default_response_char'. Assuming 'N' as a safe default." >&2
        prompt_display="[y/N]"
        default_response_char="N" # Fallback to the safer 'N' default.
    fi

    while true; do
        read -r -p "${question} ${prompt_display}: " response
        local response_lower
        response_lower=$(echo "$response" | tr '[:upper:]' '[:lower:]') # Case-insensitive comparison

        case "$response_lower" in
            y|yes)
                return 0 # User explicitly confirmed with 'y' or 'yes'.
                ;;
            n|no)
                echo "You selected 'No'. The question will be asked again. Press Ctrl+C to abort the script if you do not wish to proceed."
                # Loop continues, re-prompting the same question.
                ;;
            "") # Enter key was pressed.
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0 # Default action is 'Yes'.
                else # Default action is 'No' (or an invalid default_response_char was given).
                    echo "Default is 'No' (Enter pressed). The question will be asked again. Press Ctrl+C to abort."
                    # Loop continues, re-prompting the same question.
                fi
                ;;
            *)
                echo "Invalid input. Please type 'y' (for yes) or 'n' (for no), or press Enter to accept the default."
                ;;
        esac
    done
}

log_cmd() {
    echo "LOG: CMD: $*"
    "$@" # Execute the command
}

log_sudo_cmd() {
    echo "LOG: SUDO CMD: $*"
    sudo "$@" # Execute the command with sudo
}

# --- 0. Preamble and Critical Warning ---
echo "===================================================================="
echo "NixOS Flake-based Installation Helper Script (Debug Enhanced)"
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
confirm "Do you understand these warnings and accept full responsibility for proceeding?" "N"
# Script proceeds only if user types 'y'. Otherwise, loops here until Ctrl+C.
echo "--------------------------------------------------------------------"

# --- 1. Gather Information Interactively ---
echo "Step 1: Gathering information..."
# 1.1. Target Disk
echo ""
echo "Available block devices (physical disks, not partitions):"
lsblk -pno NAME,SIZE,MODEL # List block devices to help user identify the target.
echo ""
while true; do
    read -r -p "Enter the target disk for NixOS installation (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK
    if [[ -b "$TARGET_DISK" ]]; then # Check if it's a block device.
        TARGET_DISK_PROMPT="You have selected '$TARGET_DISK'. ALL DATA ON THIS DISK WILL BE ERASED! Are you absolutely sure?"
        confirm "$TARGET_DISK_PROMPT" "N" # Loops until 'y' is pressed. Ctrl+C to abort.
        break # Exit while loop once user explicitly confirms with 'y'.
    else
        echo "Error: '$TARGET_DISK' is not a valid block device. Please try again."
    fi
done
echo "LOG: TARGET_DISK set to: $TARGET_DISK"


# 1.2. Partitioning Constants
SWAP_SIZE_GB="16"
DEFAULT_EFI_SIZE_MiB="512"

EFI_PART_NAME="EFI"
SWAP_PART_NAME="SWAP"
ROOT_PART_NAME="ROOT_NIXOS"
DEFAULT_ROOT_FS_TYPE="ext4"
echo "LOG: SWAP_SIZE_GB=${SWAP_SIZE_GB}, DEFAULT_EFI_SIZE_MiB=${DEFAULT_EFI_SIZE_MiB}"
echo "LOG: EFI_PART_NAME=${EFI_PART_NAME}, SWAP_PART_NAME=${SWAP_PART_NAME}, ROOT_PART_NAME=${ROOT_PART_NAME}, DEFAULT_ROOT_FS_TYPE=${DEFAULT_ROOT_FS_TYPE}"


# 1.3. System Username
echo ""
read -r -p "Enter the desired username for the primary system user (e.g., ken): " NIXOS_USERNAME
while [[ -z "$NIXOS_USERNAME" ]]; do
    read -r -p "Username is required. Please enter a username: " NIXOS_USERNAME
done
echo "LOG: NIXOS_USERNAME set to: $NIXOS_USERNAME"

# 1.4. Password Setup (using mkpasswd)
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
            break
        fi
    else
        echo "Error: Passwords do not match. Please try again."
    fi
done
PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 -s)
if [[ -z "$PASSWORD_HASH" || ! "$PASSWORD_HASH" == \$6\$* ]]; then
    echo "Error: Failed to generate password hash with mkpasswd. Ensure mkpasswd is available and working."
    exit 1
fi
unset pass1
unset pass2
echo "LOG: Password hash generated."

# 1.5. Git User Information (distinct from system user)
echo ""
read -r -p "Enter your Git username (for commits, can be different from system user): " GIT_USERNAME
while [[ -z "$GIT_USERNAME" ]]; do
    read -r -p "Git username is required. Please enter one: " GIT_USERNAME
done
echo "LOG: GIT_USERNAME set to: $GIT_USERNAME"
read -r -p "Enter your Git email address (for commits): " GIT_USEREMAIL
while [[ -z "$GIT_USEREMAIL" ]]; do
    read -r -p "Git email address is required. Please enter one: " GIT_USEREMAIL
done
echo "LOG: GIT_USEREMAIL set to: $GIT_USEREMAIL"

# 1.6. Hostname
echo ""
DEFAULT_HOSTNAME="nixos"
read -r -p "Enter the system hostname (default: ${DEFAULT_HOSTNAME}): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
echo "LOG: HOSTNAME set to: $HOSTNAME"

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
confirm "Review the summary above. Do you want to proceed with these settings?" "Y"
# Loops if 'n' is pressed. Proceeds if 'y' or Enter (default Y) is pressed. Ctrl+C to abort.
echo "--------------------------------------------------------------------"

# --- 2. Disk Partitioning, Formatting, and Mounting (Using parted for layout, sgdisk for typecodes, EFI -> Root -> Swap physical order) ---
echo "Step 2: Starting disk partitioning, formatting, and mounting on $TARGET_DISK..."
echo "This will ERASE ALL DATA on $TARGET_DISK."
confirm "FINAL WARNING: Proceed with partitioning $TARGET_DISK?" "N"
# Loops if 'n' or Enter (default N) is pressed. Proceeds if 'y' is pressed. Ctrl+C to abort.

{ # Start of disk operations block
    echo "LOG: Creating new GPT partition table on $TARGET_DISK..."
    log_sudo_cmd parted --script "$TARGET_DISK" mklabel gpt
    echo "LOG: New GPT partition table created. Disk is now logically empty of partitions."
    echo "LOG: Current disk state (should show an empty GPT table or no partitions):"
    sudo parted --script "$TARGET_DISK" print
    echo "-------------------------------------"

    TOTAL_DISK_MiB_FOR_PARTED_FLOAT=$(sudo parted --script "$TARGET_DISK" unit MiB print | awk '/^Disk \// {gsub(/MiB/,""); print $3}')
    if ! [[ "$TOTAL_DISK_MiB_FOR_PARTED_FLOAT" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "Error: Could not determine total disk size in MiB for $TARGET_DISK from parted."
        sudo parted --script "$TARGET_DISK" unit MiB print
        exit 1
    fi
    TOTAL_DISK_MiB_FOR_PARTED_INT=$(printf "%.0f" "$TOTAL_DISK_MiB_FOR_PARTED_FLOAT")
    echo "LOG: Total disk size (for parted calculations): ${TOTAL_DISK_MiB_FOR_PARTED_INT}MiB"

    SWAP_SIZE_REQUESTED_MiB_INT=$((SWAP_SIZE_GB * 1024))
    echo "LOG: Requested EFI Size: ${DEFAULT_EFI_SIZE_MiB}MiB, Requested SWAP Size: ${SWAP_SIZE_REQUESTED_MiB_INT}MiB"

    EFI_PART_GPT_NAME="$EFI_PART_NAME"
    ROOT_PART_GPT_NAME="$ROOT_PART_NAME"
    SWAP_PART_GPT_NAME="$SWAP_PART_NAME"

    PART_SUFFIX_1="1"; PART_SUFFIX_2="2"; PART_SUFFIX_3="3"
    if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
        PART_SUFFIX_1="p1"; PART_SUFFIX_2="p2"; PART_SUFFIX_3="p3"
    fi
    EFI_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_1}"
    ROOT_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_2}"
    SWAP_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_3}"

    echo "LOG: Defining partition structure (EFI, Root, Swap)..."
    EFI_START_OFFSET_MiB="1"
    EFI_END_OFFSET_MiB="$((EFI_START_OFFSET_MiB + DEFAULT_EFI_SIZE_MiB))"
    log_sudo_cmd parted --script "$TARGET_DISK" unit MiB mkpart "$EFI_PART_GPT_NAME" "$EFI_START_OFFSET_MiB" "$EFI_END_OFFSET_MiB"
    log_sudo_cmd sgdisk --typecode=1:EF00 "$TARGET_DISK"
    log_sudo_cmd parted --script "$TARGET_DISK" set 1 esp on

    ROOT_START_OFFSET_MiB="$EFI_END_OFFSET_MiB"
    ROOT_END_OFFSET_MiB="$((TOTAL_DISK_MiB_FOR_PARTED_INT - SWAP_SIZE_REQUESTED_MiB_INT))"
    if [ "$(printf "%.0f" "$ROOT_START_OFFSET_MiB")" -ge "$(printf "%.0f" "$ROOT_END_OFFSET_MiB")" ]; then
        echo "Error: Calculated space for ROOT partition is invalid or too small. Check disk size and requested swap/EFI sizes."
        exit 1
    fi
    log_sudo_cmd parted --script "$TARGET_DISK" unit MiB mkpart "$ROOT_PART_GPT_NAME" "$ROOT_START_OFFSET_MiB" "$ROOT_END_OFFSET_MiB"
    log_sudo_cmd sgdisk --typecode=2:8300 "$TARGET_DISK"

    SWAP_START_OFFSET_MiB="$ROOT_END_OFFSET_MiB"
    log_sudo_cmd parted --script "$TARGET_DISK" unit MiB mkpart "$SWAP_PART_GPT_NAME" "$SWAP_START_OFFSET_MiB" 100%
    log_sudo_cmd sgdisk --typecode=3:8200 "$TARGET_DISK"

    echo "LOG: All partition definitions and type codes have been set."
    echo "LOG: Displaying partition layout BEFORE formatting."
    echo "LOG: IMPORTANT: The 'File system' column shown by 'parted' below is based on the PARTITION TYPE CODES set."
    echo "LOG:            It does NOT yet reflect actual formatted filesystems. Any pre-existing data or filesystem SIGNATURES"
    echo "LOG:            on the disk WILL BE OVERWRITTEN in the next steps."
    sudo parted --script "$TARGET_DISK" print
    echo "-------------------------------------"

    echo "LOG: Informing kernel of partition table changes..."
    log_sudo_cmd partprobe "$TARGET_DISK" && sleep 3

    echo "LOG: Proceeding to format partitions. This will ERASE any data/signatures within these defined partitions."
    echo "LOG:   - EFI Partition ($EFI_DEVICE_NODE, Name: $EFI_PART_NAME) will be formatted as FAT32."
    echo "LOG:   - Root Partition ($ROOT_DEVICE_NODE, Name: $ROOT_PART_NAME) will be formatted as $DEFAULT_ROOT_FS_TYPE."
    echo "LOG:   - Swap Partition ($SWAP_DEVICE_NODE, Name: $SWAP_PART_NAME) will be formatted as Linux Swap."
    echo "LOG: Formatting commands will use force options to overwrite any existing filesystem signatures automatically."

    echo "LOG: Formatting $EFI_DEVICE_NODE (EFI) as fat32, label: $EFI_PART_NAME..."
    log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"

    echo "LOG: Formatting $ROOT_DEVICE_NODE (ROOT) as $DEFAULT_ROOT_FS_TYPE, label: $ROOT_PART_NAME (forcing overwrite)..."
    log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE"

    echo "LOG: Creating SWAP filesystem on $SWAP_DEVICE_NODE (SWAP), label: $SWAP_PART_NAME (forcing overwrite)..."
    log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE"

    echo "LOG: Partitions have been formatted."
    echo "LOG: Final check of disk layout AFTER formatting (lsblk shows actual FSTYPE and PARTTYPE GUIDs):"
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"
    echo "-------------------------------------"

    echo "LOG: Mounting filesystems..."
    log_sudo_cmd mount -L "$ROOT_PART_NAME" /mnt
    log_sudo_cmd mkdir -p /mnt/boot
    log_sudo_cmd mount "$EFI_DEVICE_NODE" /mnt/boot
    echo "LOG: Activating SWAP by label $SWAP_PART_NAME..."
    log_sudo_cmd swapon -L "$SWAP_PART_NAME"
    echo "LOG: Filesystems mounted and swap activated."

    echo "LOG: Current mount status and block device layout:"
    df -h /mnt /mnt/boot
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"

} || {
    echo "ERROR: A critical error occurred during disk operations."
    echo "Attempting to clean up mounts..."
    sudo umount -l /mnt/boot &>/dev/null || true
    sudo umount -l /mnt &>/dev/null || true
    if [[ -n "$SWAP_DEVICE_NODE" && -e "$SWAP_DEVICE_NODE" ]]; then
        sudo swapoff "$SWAP_DEVICE_NODE" &>/dev/null || true
    elif [[ -n "$SWAP_PART_NAME" ]]; then
        sudo swapoff -L "$SWAP_PART_NAME" &>/dev/null || true
    fi
    echo "Examine logs above for details. You may need to manually clean up ${TARGET_DISK}."
    exit 1
}
echo "Disk operations completed successfully."
echo "--------------------------------------------------------------------"

# --- 3. Generate hardware-configuration.nix ---
echo "Step 3: Generating NixOS hardware configuration (hardware-configuration.nix)..."
log_sudo_cmd nixos-generate-config --root /mnt
echo "LOG: hardware-configuration.nix generated at ${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix."
if [ -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix" ]; then
    echo "Note: A base configuration.nix was also generated by nixos-generate-config."
    echo "      This base configuration.nix will NOT be used by our Flake if not explicitly listed in flake.nix's modules."
fi
echo "--------------------------------------------------------------------"

# --- 4. Generate Flake and Custom Module Files from Templates ---
echo "Step 4: Generating Flake and custom NixOS module files..."
log_sudo_cmd mkdir -p "${TARGET_NIXOS_CONFIG_DIR}"

generate_from_template() {
    local template_file_basename="$1"
    local output_file_basename="$2"
    local template_path="${TEMPLATE_DIR}/${template_file_basename}"
    local output_path="${TARGET_NIXOS_CONFIG_DIR}/${output_file_basename}"

    if [[ ! -f "$template_path" ]]; then
        echo "ERROR: Template file not found: $template_path"
        return 1
    fi

    echo "LOG: Generating $output_file_basename from $template_file_basename..."

    _escape_sed_replacement_string() {
        printf '%s\n' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g'
    }

    local escaped_nixos_username=$(_escape_sed_replacement_string "$NIXOS_USERNAME")
    local escaped_password_hash=$(_escape_sed_replacement_string "$PASSWORD_HASH")
    local escaped_git_username=$(_escape_sed_replacement_string "$GIT_USERNAME")
    local escaped_git_useremail=$(_escape_sed_replacement_string "$GIT_USEREMAIL")
    local escaped_hostname=$(_escape_sed_replacement_string "$HOSTNAME")
    local escaped_target_disk=$(_escape_sed_replacement_string "$TARGET_DISK")


    local sed_script_expressions=()
    sed_script_expressions+=("-e s|__NIXOS_USERNAME__|${escaped_nixos_username}|g")
    sed_script_expressions+=("-e s|__PASSWORD_HASH__|${escaped_password_hash}|g")
    sed_script_expressions+=("-e s|__GIT_USERNAME__|${escaped_git_username}|g")
    sed_script_expressions+=("-e s|__GIT_USEREMAIL__|${escaped_git_useremail}|g")
    sed_script_expressions+=("-e s|__HOSTNAME__|${escaped_hostname}|g")
    sed_script_expressions+=("-e s|__TARGET_DISK_FOR_GRUB__|${escaped_target_disk}|g")

    local temp_output
    temp_output=$(mktemp)

    echo "LOG: Applying sed script to ${template_file_basename}..."
    if command sudo sed "${sed_script_expressions[@]}" "${template_path}" > "${temp_output}"; then
        if sudo mv "$temp_output" "$output_path"; then
            echo "LOG: ${output_file_basename} generated successfully at ${output_path}."
            sudo chmod 644 "$output_path"
        else
            echo "ERROR: Failed to move temporary file to ${output_path} (sudo mv \"$temp_output\" \"$output_path\")."
            rm -f "$temp_output"
            return 1
        fi
    else
        echo "ERROR: sed command failed for generating ${output_file_basename} from ${template_file_basename}."
        rm -f "$temp_output"
        return 1
    fi
    return 0
}

# List of templates and their corresponding output file names.
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

# Generate each module file from its template.
for item in "${module_templates[@]}"; do
    IFS=":" read -r template_name output_name <<< "$item" # Split "template:output"
    if ! generate_from_template "$template_name" "$output_name"; then
        echo "ERROR: Failed to generate ${output_name}. Aborting installation."
        exit 1
    fi
done

# Copy user-provided Zellij config files (from templates/config/)
# to /mnt/etc/nixos/ so home-manager-user.nix can source them with ./
echo "Copying user-provided configuration files (for Zellij)..."
if [[ -d "$USER_CONFIG_FILES_DIR" ]]; then
    for user_cfg_file in key-bindings.kdl layout-file.kdl; do # Add other files to this loop if needed
        if [[ -f "${USER_CONFIG_FILES_DIR}/${user_cfg_file}" ]]; then
            if sudo cp "${USER_CONFIG_FILES_DIR}/${user_cfg_file}" "${TARGET_NIXOS_CONFIG_DIR}/${user_cfg_file}"; then
                echo "LOG: ${user_cfg_file} copied successfully to ${TARGET_NIXOS_CONFIG_DIR}/."
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
confirm "Proceed with NixOS installation?" "Y"
# Loops if 'n' is pressed. Proceeds if 'y' or Enter (default Y) is pressed. Ctrl+C to abort.

# ========== INSERTED DEBUG BLOCK START ==========
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!! DEBUG: About to display generated config files for your inspection.    !!!"
echo "!!! This is to help diagnose issues with Nix/Home Manager option errors.   !!!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo ""

echo "DEBUG: Displaying content of /mnt/etc/nixos/flake.nix (as generated by this script):"
echo "------------------------------------------------------------------------------------"
if [ -f /mnt/etc/nixos/flake.nix ]; then
    sudo cat /mnt/etc/nixos/flake.nix
else
    echo "DEBUG: /mnt/etc/nixos/flake.nix NOT FOUND!"
fi
echo "------------------------------------------------------------------------------------"
echo ""

echo "DEBUG: Displaying content of /mnt/etc/nixos/home-manager-user.nix (as generated by this script):"
echo "---------------------------------------------------------------------------------------------------"
if [ -f /mnt/etc/nixos/home-manager-user.nix ]; then
    sudo cat /mnt/etc/nixos/home-manager-user.nix
else
    echo "DEBUG: /mnt/etc/nixos/home-manager-user.nix NOT FOUND!"
fi
echo "---------------------------------------------------------------------------------------------------"
echo ""
read -r -p "DEBUG: Config files have been displayed. Press Enter to proceed with 'nixos-install', or Ctrl+C to abort and review the files/templates..."
# ========== INSERTED DEBUG BLOCK END ==========

echo "LOG: Starting nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"
# The actual installation command.
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

echo "===================================================================="
echo "Script finished."
exit 0
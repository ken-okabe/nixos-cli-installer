#!/usr/bin/env bash

# === Initial Setup and Error Handling ===
set -e # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for extreme debugging (prints every command executed)

# Get the directory where the script is located to reference template files.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
TARGET_NIXOS_CONFIG_DIR="/mnt/etc/nixos"                # NixOS config on the target mount

# === Function Definitions ===
confirm() {
    local question="$1"
    local default_response_char="$2" # Expected to be "Y" or "N"
    local prompt_display=""

    if [[ "$default_response_char" == "Y" ]]; then
        prompt_display="[Y/n]"
    elif [[ "$default_response_char" == "N" ]]; then
        prompt_display="[y/N]"
    else
        echo "DEVELOPER ERROR: confirm function called with invalid default_response_char: '$default_response_char'. Assuming 'N' as a safe default." >&2
        prompt_display="[y/N]"
        default_response_char="N"
    fi

    while true; do
        read -r -p "${question} ${prompt_display}: " response
        local response_lower
        response_lower=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response_lower" in
            y|yes)
                return 0
                ;;
            n|no)
                echo "You selected 'No'. The question will be asked again. Press Ctrl+C to abort the script if you do not wish to proceed."
                ;;
            "")
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0
                else
                    echo "Default is 'No' (Enter pressed). The question will be asked again. Press Ctrl+C to abort."
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
    "$@"
}

log_sudo_cmd() {
    echo "LOG: SUDO CMD: $*"
    sudo "$@"
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
echo "--------------------------------------------------------------------"

# --- 1. Gather Information Interactively ---
echo "Step 1: Gathering information..."
echo ""
echo "Available block devices (physical disks, not partitions):"
lsblk -pno NAME,SIZE,MODEL
echo ""
while true; do
    read -r -p "Enter the target disk for NixOS installation (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK
    if [[ -b "$TARGET_DISK" ]]; then
        TARGET_DISK_PROMPT="You have selected '$TARGET_DISK'. ALL DATA ON THIS DISK WILL BE ERASED! Are you absolutely sure?"
        confirm "$TARGET_DISK_PROMPT" "N"
        break
    else
        echo "Error: '$TARGET_DISK' is not a valid block device. Please try again."
    fi
done
echo "LOG: TARGET_DISK set to: $TARGET_DISK"

SWAP_SIZE_GB="16"
DEFAULT_EFI_SIZE_MiB="512"
EFI_PART_NAME="EFI" # Used for mkfs.vfat label and sfdisk partition name
SWAP_PART_NAME="SWAP" # Used for mkswap label, swapon/swapoff by label, and sfdisk partition name
ROOT_PART_NAME="ROOT_NIXOS" # Used for mkfs label and sfdisk partition name
DEFAULT_ROOT_FS_TYPE="ext4"
echo "LOG: SWAP_SIZE_GB=${SWAP_SIZE_GB}, DEFAULT_EFI_SIZE_MiB=${DEFAULT_EFI_SIZE_MiB}"
echo "LOG: EFI_PART_NAME=${EFI_PART_NAME}, SWAP_PART_NAME=${SWAP_PART_NAME}, ROOT_PART_NAME=${ROOT_PART_NAME}, DEFAULT_ROOT_FS_TYPE=${DEFAULT_ROOT_FS_TYPE}"

# These will be defined later based on partition numbers (e.g., /dev/sda1)
EFI_DEVICE_NODE=""
ROOT_DEVICE_NODE=""
SWAP_DEVICE_NODE=""

echo ""
read -r -p "Enter the desired username for the primary system user (e.g., ken): " NIXOS_USERNAME
while [[ -z "$NIXOS_USERNAME" ]]; do
    read -r -p "Username is required. Please enter a username: " NIXOS_USERNAME
done
echo "LOG: NIXOS_USERNAME set to: $NIXOS_USERNAME"

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
echo "--------------------------------------------------------------------"

# --- 2. Disk Partitioning, Formatting, and Mounting (using sfdisk) ---
echo "Step 2: Starting disk partitioning, formatting, and mounting on $TARGET_DISK..."
echo "This will ERASE ALL DATA on $TARGET_DISK."
confirm "FINAL WARNING: Proceed with partitioning $TARGET_DISK?" "N"

{
    echo "LOG: Attempting to unmount target filesystems and turn off swap if active..."
    if mountpoint -q /mnt/boot; then
        echo "LOG: /mnt/boot is mounted. Attempting to unmount..."
        sudo umount -f /mnt/boot || echo "WARN: Failed to unmount /mnt/boot. It might be busy or already unmounted."
    fi
    if mountpoint -q /mnt; then
        echo "LOG: /mnt is mounted. Attempting to unmount..."
        sudo umount -f /mnt || echo "WARN: Failed to unmount /mnt. It might be busy or already unmounted."
    fi

    if [[ -n "$SWAP_PART_NAME" ]]; then
        echo "LOG: Attempting to swapoff by label $SWAP_PART_NAME (if it exists from a previous run)..."
        sudo swapoff -L "$SWAP_PART_NAME" &>/dev/null || true # Ignore errors, might not exist
    fi
    echo "LOG: Attempting to swapoff all active swap partitions (swapoff -a)..."
    sudo swapoff -a &>/dev/null || true # Ignore errors
    echo "LOG: Finished attempting to unmount and turn off swap."
    sleep 2

    # Get total disk size in MiB
    TOTAL_DISK_BYTES=$(sudo blockdev --getsize64 "$TARGET_DISK")
    if ! [[ "$TOTAL_DISK_BYTES" =~ ^[0-9]+$ ]] || [ "$TOTAL_DISK_BYTES" -eq 0 ]; then
        echo "Error: Could not determine total disk size in bytes for $TARGET_DISK from blockdev."
        exit 1
    fi
    TOTAL_DISK_MiB=$((TOTAL_DISK_BYTES / 1024 / 1024))
    echo "LOG: Total disk size (for sfdisk calculations): ${TOTAL_DISK_MiB}MiB"

    # Calculate partition sizes and offsets in MiB
    EFI_START_OFFSET_MiB="1" # 1MiB offset for GPT alignment
    EFI_SIZE_MiB_ACTUAL="${DEFAULT_EFI_SIZE_MiB}"

    SWAP_SIZE_REQUESTED_MiB_INT=$((SWAP_SIZE_GB * 1024))

    ROOT_START_OFFSET_MiB_ACTUAL="$((EFI_START_OFFSET_MiB + EFI_SIZE_MiB_ACTUAL))"
    ROOT_END_OFFSET_MiB_ACTUAL="$((TOTAL_DISK_MiB - SWAP_SIZE_REQUESTED_MiB_INT))"
    ROOT_SIZE_MiB_ACTUAL="$((ROOT_END_OFFSET_MiB_ACTUAL - ROOT_START_OFFSET_MiB_ACTUAL))"

    SWAP_START_OFFSET_MiB_ACTUAL="$ROOT_END_OFFSET_MiB_ACTUAL"

    if [ "$ROOT_SIZE_MiB_ACTUAL" -le 0 ]; then
        echo "Error: Calculated space for ROOT partition is invalid or too small (${ROOT_SIZE_MiB_ACTUAL}MiB). Check disk size and requested swap/EFI sizes."
        echo "DEBUG: TOTAL_DISK_MiB=${TOTAL_DISK_MiB}, EFI_START_OFFSET_MiB=${EFI_START_OFFSET_MiB}, EFI_SIZE_MiB_ACTUAL=${EFI_SIZE_MiB_ACTUAL}, SWAP_SIZE_REQUESTED_MiB_INT=${SWAP_SIZE_REQUESTED_MiB_INT}"
        exit 1
    fi
    # Sanity check: ensure calculated total MiB for partitions does not exceed disk MiB
    # (This is a rough check due to potential 1MiB offset and integer arithmetic)
    CALCULATED_TOTAL_PART_MiB=$((EFI_SIZE_MiB_ACTUAL + ROOT_SIZE_MiB_ACTUAL + SWAP_SIZE_REQUESTED_MiB_INT))
    if [ "$CALCULATED_TOTAL_PART_MiB" -gt "$((TOTAL_DISK_MiB - EFI_START_OFFSET_MiB + 1))" ]; then # +1 for safety margin with integer math
        echo "Error: Calculated total partition size (${CALCULATED_TOTAL_PART_MiB}MiB + ${EFI_START_OFFSET_MiB}MiB offset) might exceed disk size (${TOTAL_DISK_MiB}MiB)."
        exit 1
    fi


    echo "LOG: Calculated partition MiB values: EFI_start=${EFI_START_OFFSET_MiB}, EFI_size=${EFI_SIZE_MiB_ACTUAL}, Root_start=${ROOT_START_OFFSET_MiB_ACTUAL}, Root_size=${ROOT_SIZE_MiB_ACTUAL}, Swap_start=${SWAP_START_OFFSET_MiB_ACTUAL}, Swap_size=${SWAP_SIZE_REQUESTED_MiB_INT}"

    # Define GPT partition type GUIDs
    EFI_TYPE_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"  # EFI System Partition
    ROOT_TYPE_GUID="0FC63DAF-8483-4772-8E79-3D69D8477DE4" # Linux filesystem
    SWAP_TYPE_GUID="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" # Linux swap

    # Determine partition device node suffixes (e.g., "1" or "p1")
    PART_SUFFIX_1="1"; PART_SUFFIX_2="2"; PART_SUFFIX_3="3"
    if [[ "$TARGET_DISK" == /dev/nvme* ]]; then
        PART_SUFFIX_1="p1"; PART_SUFFIX_2="p2"; PART_SUFFIX_3="p3"
    fi
    EFI_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_1}"
    ROOT_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_2}"
    SWAP_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_3}"

    # Prepare sfdisk input using a here-document
    # No "unit:" directive, no comments. Sizes use 'M' suffix.
SFDISK_INPUT=$(cat <<EOF
label: gpt
name="${EFI_PART_NAME}", start=${EFI_START_OFFSET_MiB}M, size=${EFI_SIZE_MiB_ACTUAL}M, type=${EFI_TYPE_GUID}
name="${ROOT_PART_NAME}", start=${ROOT_START_OFFSET_MiB_ACTUAL}M, size=${ROOT_SIZE_MiB_ACTUAL}M, type=${ROOT_TYPE_GUID}
name="${SWAP_PART_NAME}", start=${SWAP_START_OFFSET_MiB_ACTUAL}M, size=${SWAP_SIZE_REQUESTED_MiB_INT}M, type=${SWAP_TYPE_GUID}
EOF
)
    echo "LOG: sfdisk input prepared:"
    echo -e "------ Start of SFDISK_INPUT ------\n${SFDISK_INPUT}\n------- End of SFDISK_INPUT -------" # Make it clear in logs

    echo "LOG: Applying partition scheme using sfdisk on $TARGET_DISK..."
    # --wipe always: Erases existing signatures and creates a new partition table.
    # --wipe-partitions always: Wipes filesystem signatures from newly created partitions.
    # Use printf to pass input to avoid potential issues with echo and special characters in SFDISK_INPUT (though unlikely here)
    printf "%s" "${SFDISK_INPUT}" | log_sudo_cmd sfdisk \
        --wipe always \
        --wipe-partitions always \
        "$TARGET_DISK"

    echo "LOG: Partition scheme applied with sfdisk."
    echo "LOG: Informing kernel of partition table changes..."
    sync
    # Attempt multiple methods to inform kernel, as one might fail in some environments
    echo "LOG: Attempt 1: partprobe ${TARGET_DISK}"
    if sudo partprobe "$TARGET_DISK"; then
        echo "LOG: partprobe successful."
    else
        echo "WARN: partprobe failed on attempt 1. Trying blockdev..."
        sleep 3
        echo "LOG: Attempt 2: blockdev --rereadpt ${TARGET_DISK}"
        if sudo blockdev --rereadpt "$TARGET_DISK"; then
            echo "LOG: blockdev --rereadpt successful."
        else
            echo "WARN: blockdev --rereadpt also failed. Kernel might use old partition table. Manual intervention might be needed if formatting fails."
        fi
    fi
    sleep 2 # Give kernel a moment
    echo "LOG: Finished attempting to inform kernel of partition changes."

    echo "LOG: Verifying partition layout AFTER sfdisk (using sfdisk -l and lsblk)."
    sudo sfdisk -l "$TARGET_DISK"
    echo "-------------------------------------"
    # Note: FSTYPE and LABEL will be populated after mkfs commands.
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"
    echo "-------------------------------------"

    echo "LOG: Proceeding to format partitions..."
    log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"
    log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE"
    log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE"

    echo "LOG: Partitions have been formatted."
    echo "LOG: Final check of disk layout AFTER formatting:"
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"
    echo "-------------------------------------"

    echo "LOG: Mounting filesystems..."
    log_sudo_cmd mount -L "$ROOT_PART_NAME" /mnt
    log_sudo_cmd mkdir -p /mnt/boot
    log_sudo_cmd mount "$EFI_DEVICE_NODE" /mnt/boot # Mount by device node
    echo "LOG: Activating SWAP by label $SWAP_PART_NAME..."
    log_sudo_cmd swapon -L "$SWAP_PART_NAME"
    echo "LOG: Filesystems mounted and swap activated."

    echo "LOG: Current mount status and block device layout:"
    df -h /mnt /mnt/boot
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"

} || {
    echo "ERROR: A critical error occurred during disk operations."
    echo "Attempting to clean up mounts and swap..."
    if mountpoint -q /mnt/boot; then sudo umount -lf /mnt/boot &>/dev/null || true; fi
    if mountpoint -q /mnt; then sudo umount -lf /mnt &>/dev/null || true; fi
    if [[ -n "$SWAP_DEVICE_NODE" && -e "$SWAP_DEVICE_NODE" ]]; then
        sudo swapoff "$SWAP_DEVICE_NODE" &>/dev/null || true
    elif [[ -n "$SWAP_PART_NAME" ]]; then
        sudo swapoff -L "$SWAP_PART_NAME" &>/dev/null || true
    else
        sudo swapoff -a &>/dev/null || true
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
    echo "LOG: Removing the generated base ${TARGET_NIXOS_CONFIG_DIR}/configuration.nix as it is not used."
    log_sudo_cmd rm -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"
fi
echo "--------------------------------------------------------------------"

# --- 4. Generate Flake and Custom Module Files from Templates ---
echo "Step 4: Generating Flake and custom NixOS module files..."
log_sudo_cmd mkdir -p "${TARGET_NIXOS_CONFIG_DIR}"
echo "LOG: Ensured ${TARGET_NIXOS_CONFIG_DIR} exists."

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
        printf '%s\n' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g' # Also escape pipe for sed s|...|...|
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
            sudo chmod 644 "$output_path" # Set reasonable permissions
        else
            echo "ERROR: Failed to move temporary file to ${output_path} (sudo mv \"$temp_output\" \"$output_path\")."
            rm -f "$temp_output" # Clean up temp file on error
            return 1
        fi
    else
        echo "ERROR: sed command failed for generating ${output_file_basename} from ${template_file_basename}."
        rm -f "$temp_output" # Clean up temp file on error
        return 1
    fi
}

declare -a module_templates=(
    "flake.nix.template:flake.nix"
    "system-settings.nix.template:system-settings.nix"
    "users.nix.template:users.nix"
    "system-packages.nix.template:system-packages.nix"
    "gnome-desktop.nix.template:gnome-desktop.nix"
    "fonts-ime.nix.template:fonts-ime.nix"
    "sound.nix.template:sound.nix"
    "networking.nix.template:networking.nix"
    "bluetooth.nix.template:bluetooth.nix"
    "virtualbox-guest.nix.template:virtualbox-guest.nix"
    "system-customizations.nix.template:system-customizations.nix"
    "key-remap.nix.template:key-remap.nix"
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

echo "All NixOS configuration files generated and placed in ${TARGET_NIXOS_CONFIG_DIR}/."
echo "--------------------------------------------------------------------"

# --- 5. Install NixOS ---
echo "Step 5: Installing NixOS using the Flake configuration..."
echo "This process will take a significant amount of time. Please be patient."
echo "You will see a lot of build output."
echo ""
confirm "Proceed with NixOS installation?" "Y"

echo "LOG: Starting nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"
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
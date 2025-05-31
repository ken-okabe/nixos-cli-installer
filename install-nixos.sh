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
        # Developer error, not user error.
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
                return 0 # Success (Yes)
                ;;
            n|no)
                # If 'No', prompt again. User must Ctrl+C to abort if they don't want to proceed at all.
                echo "You selected 'No'. The question will be asked again. Press Ctrl+C to abort the script if you do not wish to proceed."
                ;;
            "") # Empty input, choose default
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0 # Success (Default was Yes)
                else
                    # If default is 'No', prompt again.
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

# Helper function to escape strings for use in sed single line replacement
_escape_sed_replacement_string_singleline() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/|/\\|/g' -e "s/'/'\\\\''/g" -e 's/"/\\"/g' -e 's/%/\\%/g' -e 's/\//\\\//g'
}

# Helper function to escape strings for use in sed pattern (like the placeholder)
_escape_sed_pattern_string() {
    printf '%s' "$1" | sed -e 's/[\/&*$]/\\&/g' -e 's/%/\\%/g' 
}

# Helper function to escape strings for use in sed MULTI-LINE replacement
_escape_sed_replacement_string_multiline() {
    # For multi-line replacement, we need to escape &, \, and the delimiter used in sed (e.g., %)
    # Newlines should be preserved as actual newlines.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/&/\\&/g' -e 's/%/\\%/g'
}


# This function generates the flake.nix, substitutes user variables,
# and injects the dynamically generated list of module imports.
generate_flake_with_modules() {
    local template_file_basename="$1" # e.g., flake.nix.template
    local output_file_basename="$2"   # e.g., flake.nix
    local template_path="${TEMPLATE_DIR}/${template_file_basename}"
    local output_path_final="${TARGET_NIXOS_CONFIG_DIR}/${output_file_basename}"
    local nixos_module_imports_string="$3" # Pass the pre-generated module imports string as the third argument

    if [[ ! -f "$template_path" ]]; then
        echo "ERROR: Template file not found: $template_path"
        return 1
    fi

    echo "LOG: Generating initial $output_file_basename from $template_file_basename (pass 1)..."

    # Sed script for the first pass (variable substitution)
    # Using | as delimiter for sed here as __PLACEHOLDERS__ are unlikely to contain it.
    local sed_script_pass1_cmds="
      s|__NIXOS_USERNAME__|$(_escape_sed_replacement_string_singleline "$NIXOS_USERNAME")|g;
      s|__PASSWORD_HASH__|$(_escape_sed_replacement_string_singleline "$PASSWORD_HASH")|g;
      s|__GIT_USERNAME__|$(_escape_sed_replacement_string_singleline "$GIT_USERNAME")|g;
      s|__GIT_USEREMAIL__|$(_escape_sed_replacement_string_singleline "$GIT_USEREMAIL")|g;
      s|__HOSTNAME__|$(_escape_sed_replacement_string_singleline "$HOSTNAME")|g;
      s|__TARGET_DISK_FOR_GRUB__|$(_escape_sed_replacement_string_singleline "$TARGET_DISK")|g;
    "

    local temp_output_pass1
    temp_output_pass1=$(mktemp)

    # Apply the first pass of substitutions
    # The template_path needs to be readable by the current user if sudo is not used for sed reading part
    if ! sed "$sed_script_pass1_cmds" "${template_path}" > "${temp_output_pass1}"; then
        echo "ERROR: sed command (pass 1 - variable substitution) failed for ${output_file_basename}."
        rm -f "$temp_output_pass1"
        return 1
    fi
    echo "LOG: Pass 1 (variable substitution) for ${output_file_basename} successful."

    # Pass 2: Insert the dynamic module list
    echo "LOG: Inserting dynamic module list into ${output_file_basename} (pass 2)..."
    local placeholder_to_replace="#__NIXOS_MODULE_IMPORTS_PLACEHOLDER__#"
    # Ensure placeholder is escaped for sed pattern
    local escaped_placeholder_pattern=$(_escape_sed_pattern_string "$placeholder_to_replace")

    # For the replacement string (module imports), escape characters that have special meaning in sed's replacement part
    local escaped_module_imports_for_sed_replacement
    escaped_module_imports_for_sed_replacement=$(_escape_sed_replacement_string_multiline "${nixos_module_imports_string}")


    local temp_output_pass2
    temp_output_pass2=$(mktemp)
    local sed_script_file_pass2
    sed_script_file_pass2=$(mktemp)

    # Create a sed script file for the multi-line replacement.
    # Using % as delimiter.
    printf 's%%%s%%%s%%g\n' "$escaped_placeholder_pattern" "$escaped_module_imports_for_sed_replacement" > "$sed_script_file_pass2"


    if sed -f "$sed_script_file_pass2" "${temp_output_pass1}" > "${temp_output_pass2}"; then
        # Moving the final file needs sudo as TARGET_NIXOS_CONFIG_DIR is in /mnt
        if sudo mv "$temp_output_pass2" "$output_path_final"; then
            echo "LOG: ${output_file_basename} generated successfully with dynamic modules at ${output_path_final}."
            sudo chmod 644 "$output_path_final"
            rm -f "$temp_output_pass1" "$sed_script_file_pass2" # temp_output_pass2 was moved
        else
            echo "ERROR: Failed to move final ${output_file_basename} to ${output_path_final}."
            rm -f "$temp_output_pass1" "$temp_output_pass2" "$sed_script_file_pass2"
            return 1
        fi
    else
        echo "ERROR: sed command (pass 2 - module import injection) failed for ${output_file_basename}."
        echo "DEBUG: Sed script content of $sed_script_file_pass2:"
        cat "$sed_script_file_pass2" # Show the sed script for debugging
        rm -f "$temp_output_pass1" "$temp_output_pass2" "$sed_script_file_pass2"
        return 1
    fi
}


# --- 0. Preamble and Critical Warning ---
echo "===================================================================="
echo "NixOS Flake-based Installation Helper Script (User Provided Base)"
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
echo "           4. Ensure the selected TARGET DISK is prepared as an UNDEFINED DRIVE"
echo "              (e.g., no existing partitions or valuable data). This script will"
echo "              attempt to wipe it completely. For re-attempts, ensure the disk is"
echo "              in a clean state or understand that existing partitions will be destroyed."
echo "           5. This script will use '/mnt' and '/mnt/boot' as temporary mount points."
echo "              If these are currently in use by other devices, you will be asked for"
echo "              confirmation to unmount them."
echo "--------------------------------------------------------------------"
confirm "Do you understand these warnings and accept full responsibility for proceeding?" "N"
echo "--------------------------------------------------------------------"

# --- 1. Gather Information Interactively ---
echo "Step 1: Gathering information..."
echo ""
echo "Available block devices (physical disks, not partitions):"
lsblk -pno NAME,SIZE,MODEL # Show physical disks
echo ""
while true; do
    read -r -p "Enter the target disk for NixOS installation (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK
    if [[ -b "$TARGET_DISK" ]]; then # Check if it's a block device
        TARGET_DISK_PROMPT="You have selected '$TARGET_DISK'. ALL DATA ON THIS DISK WILL BE ERASED! Are you absolutely sure?"
        if confirm "$TARGET_DISK_PROMPT" "N"; then # Default to No for safety
             break # Break if user confirms 'Yes'
        fi
    else
        echo "Error: '$TARGET_DISK' is not a valid block device. Please try again."
    fi
done
echo "LOG: TARGET_DISK set to: $TARGET_DISK"

SWAP_SIZE_GB="16"
DEFAULT_EFI_SIZE_MiB="512"
EFI_PART_NAME="EFI"
SWAP_PART_NAME="SWAP"
ROOT_PART_NAME="ROOT_NIXOS"
DEFAULT_ROOT_FS_TYPE="ext4"
echo "LOG: SWAP_SIZE_GB=${SWAP_SIZE_GB}, DEFAULT_EFI_SIZE_MiB=${DEFAULT_EFI_SIZE_MiB}"
echo "LOG: EFI_PART_NAME=${EFI_PART_NAME}, SWAP_PART_NAME=${SWAP_PART_NAME}, ROOT_PART_NAME=${ROOT_PART_NAME}, DEFAULT_ROOT_FS_TYPE=${DEFAULT_ROOT_FS_TYPE}"

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
# Assuming mkpasswd is from shadow utils, '-s' without argument means read password from stdin and generate salt
PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 -s)
if [[ -z "$PASSWORD_HASH" || ! "$PASSWORD_HASH" == \$6\$* ]]; then # Check for $6$ prefix for SHA512 crypt
    echo "Error: Failed to generate password hash with mkpasswd. Ensure mkpasswd is available and working as expected (e.g., from shadow utils)."
    exit 1
fi
unset pass1 pass2
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
confirm "Review the summary above. Do you want to proceed with these settings?" "Y" # Default to Yes
echo "--------------------------------------------------------------------"

# --- 2. Disk Partitioning, Formatting, and Mounting (using sfdisk) ---
echo "Step 2: Starting disk partitioning, formatting, and mounting on $TARGET_DISK..."
confirm "FINAL WARNING: ALL DATA ON '$TARGET_DISK' WILL BE ERASED. Proceed with partitioning?" "N" # Default to No for safety

# Group disk operations; if any fail (due to set -e), the || {...} block will execute.
{
    echo "LOG: Checking and preparing /mnt and /mnt/boot mount points..."
    MOUNT_POINTS_TO_CLEAN=("/mnt/boot" "/mnt") # Unmount /mnt/boot before /mnt for safety
    for mp_to_clean in "${MOUNT_POINTS_TO_CLEAN[@]}"; do
        if mountpoint -q "$mp_to_clean"; then
            current_mounted_device=$(findmnt -n -o SOURCE --target "$mp_to_clean")
            echo "INFO: '$mp_to_clean' is currently mounted by '$current_mounted_device'."
            is_target_disk_partition=false
            # Heuristic: check if the current device path starts with the target disk path
            if [[ "$current_mounted_device" == "$TARGET_DISK"* ]]; then
                is_target_disk_partition=true
            fi

            if $is_target_disk_partition; then
                 echo "INFO: '$current_mounted_device' appears to be a partition of the target disk '$TARGET_DISK'."
                 echo "       This might be from a previous incomplete run. Attempting to unmount..."
                 log_sudo_cmd umount -f "$mp_to_clean" # Using your log_sudo_cmd
            else
                # If it's not part of the target disk, be more careful
                if confirm "Mount point '$mp_to_clean' is in use by '$current_mounted_device' (which is NOT the target disk '$TARGET_DISK'). Unmount it to proceed with installation?" "N"; then
                    log_sudo_cmd umount -f "$mp_to_clean"
                    echo "LOG: '$mp_to_clean' unmounted."
                else
                    echo "ERROR: User chose not to unmount '$mp_to_clean'. Installation cannot proceed safely." >&2
                    echo "       Please ensure '$mp_to_clean' is free before running the script." >&2
                    exit 1 # Exit because we can't proceed
                fi
            fi
        else
            echo "LOG: '$mp_to_clean' is not currently a mountpoint or is not mounted. Good."
        fi
    done

    echo "LOG: Attempting to turn off swap if active..."
    if [[ -n "$SWAP_PART_NAME" ]]; then # Check if SWAP_PART_NAME is non-empty
        echo "LOG: Attempting to swapoff by label $SWAP_PART_NAME (if it exists from a previous run)..."
        sudo swapoff -L "$SWAP_PART_NAME" &>/dev/null || true # Suppress errors, try best effort
    fi
    echo "LOG: Attempting to swapoff all active swap partitions (swapoff -a) as a general measure..."
    sudo swapoff -a &>/dev/null || true # Suppress errors
    echo "LOG: Finished attempting to turn off swap."
    sleep 2 # Give system a moment to release swap devices

    # Get total disk size in MiB for sfdisk calculations.
    TOTAL_DISK_BYTES=$(sudo blockdev --getsize64 "$TARGET_DISK")
    if ! [[ "$TOTAL_DISK_BYTES" =~ ^[0-9]+$ ]] || [ "$TOTAL_DISK_BYTES" -eq 0 ]; then
        echo "Error: Could not determine total disk size in bytes for $TARGET_DISK from blockdev."
        exit 1
    fi
    TOTAL_DISK_MiB=$((TOTAL_DISK_BYTES / 1024 / 1024))
    echo "LOG: Total disk size (for sfdisk calculations): ${TOTAL_DISK_MiB}MiB"

    # Calculate partition sizes
    EFI_START_OFFSET_MiB="1" # Start EFI at 1MiB for alignment
    EFI_SIZE_MiB_ACTUAL="${DEFAULT_EFI_SIZE_MiB}"
    SWAP_SIZE_REQUESTED_MiB_INT=$((SWAP_SIZE_GB * 1024))

    # Root partition starts after EFI
    ROOT_START_OFFSET_MiB_ACTUAL="$((EFI_START_OFFSET_MiB + EFI_SIZE_MiB_ACTUAL))"
    # Swap partition is at the end of the disk
    SWAP_START_OFFSET_MiB_ACTUAL="$((TOTAL_DISK_MiB - SWAP_SIZE_REQUESTED_MiB_INT))"
    # Root partition size is the space between its start and the start of swap
    ROOT_SIZE_MiB_ACTUAL="$((SWAP_START_OFFSET_MiB_ACTUAL - ROOT_START_OFFSET_MiB_ACTUAL))"


    # Sanity checks for calculated sizes
    if [ "$ROOT_SIZE_MiB_ACTUAL" -le 10240 ]; then # Minimum 10GiB for root
        echo "Error: Calculated space for ROOT partition is too small (${ROOT_SIZE_MiB_ACTUAL}MiB). Minimum recommended: 10240MiB."
        exit 1
    fi
    if [ "$SWAP_START_OFFSET_MiB_ACTUAL" -le "$ROOT_START_OFFSET_MiB_ACTUAL" ]; then
        echo "Error: Swap partition start offset is before or same as root partition start. Check disk size and swap size."
        exit 1
    fi

    echo "LOG: Calculated partition MiB values: EFI_start=${EFI_START_OFFSET_MiB}, EFI_size=${EFI_SIZE_MiB_ACTUAL}, Root_start=${ROOT_START_OFFSET_MiB_ACTUAL}, Root_size=${ROOT_SIZE_MiB_ACTUAL}, Swap_start=${SWAP_START_OFFSET_MiB_ACTUAL}, Swap_size=${SWAP_SIZE_REQUESTED_MiB_INT}"

    # Define partition type GUIDs
    EFI_TYPE_GUID="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"  # EFI System
    ROOT_TYPE_GUID="0FC63DAF-8483-4772-8E79-3D69D8477DE4" # Linux x86-64 root (/)
    SWAP_TYPE_GUID="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" # Linux swap

    # Determine partition number suffixes (e.g., 1, 2, 3 or p1, p2, p3)
    PART_SUFFIX_1="1"; PART_SUFFIX_2="2"; PART_SUFFIX_3="3"
    if [[ "$TARGET_DISK" == /dev/nvme* || "$TARGET_DISK" == /dev/loop* ]]; then
        PART_SUFFIX_1="p1"; PART_SUFFIX_2="p2"; PART_SUFFIX_3="p3"
    fi
    EFI_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_1}"
    ROOT_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_2}"
    SWAP_DEVICE_NODE="${TARGET_DISK}${PART_SUFFIX_3}"
    echo "LOG: EFI Device Node will be: ${EFI_DEVICE_NODE}"
    echo "LOG: Root Device Node will be: ${ROOT_DEVICE_NODE}"
    echo "LOG: Swap Device Node will be: ${SWAP_DEVICE_NODE}"

# Prepare sfdisk input script string using calculated values with 'M' suffix for MiB
# Note: sfdisk expects sizes, not end points for the size parameter.
SFDISK_INPUT=$(cat <<EOF
label: gpt
name="${EFI_PART_NAME}", start=${EFI_START_OFFSET_MiB}M, size=${EFI_SIZE_MiB_ACTUAL}M, type=${EFI_TYPE_GUID}
name="${ROOT_PART_NAME}", start=${ROOT_START_OFFSET_MiB_ACTUAL}M, size=${ROOT_SIZE_MiB_ACTUAL}M, type=${ROOT_TYPE_GUID}
name="${SWAP_PART_NAME}", start=${SWAP_START_OFFSET_MiB_ACTUAL}M, size=${SWAP_SIZE_REQUESTED_MiB_INT}M, type=${SWAP_TYPE_GUID}
EOF
)
    echo "LOG: sfdisk input prepared:"
    echo -e "------ Start of SFDISK_INPUT ------\n${SFDISK_INPUT}\n------- End of SFDISK_INPUT -------" # Log the input

    echo "LOG: Applying partition scheme using sfdisk on $TARGET_DISK..."
    # Pipe the input to sfdisk. log_sudo_cmd will handle logging the command execution.
    printf "%s" "${SFDISK_INPUT}" | log_sudo_cmd sfdisk \
        --wipe always \
        --wipe-partitions always \
        "$TARGET_DISK"

    echo "LOG: Partition scheme applied with sfdisk."
    echo "LOG: Informing kernel of partition table changes..."
    sync # Flush buffers
    # Try to re-read partition table. partprobe can fail sometimes.
    if ! sudo partprobe "$TARGET_DISK"; then
        echo "WARN: partprobe failed on attempt 1. Trying blockdev..."
        sleep 3 # Give a moment before trying alternative
        if ! sudo blockdev --rereadpt "$TARGET_DISK"; then
            echo "WARN: blockdev --rereadpt also failed. The kernel might use an old partition table. This could cause issues."
        fi
    fi
    sleep 2 # Give udev time to create device nodes
    echo "LOG: Finished attempting to inform kernel of partition changes."

    # Display the resulting partition table for verification by user / logs
    echo "LOG: Current partition table on ${TARGET_DISK} after sfdisk:"
    sudo sfdisk -l "$TARGET_DISK" # Show partition table
    # Also show with lsblk for more filesystem-oriented view after formatting
    echo "LOG: Block device overview (lsblk) before formatting:"
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"


    # Format the partitions
    echo "LOG: Formatting EFI partition (${EFI_DEVICE_NODE}) as FAT32..."
    log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"
    echo "LOG: Formatting Root partition (${ROOT_DEVICE_NODE}) as ${DEFAULT_ROOT_FS_TYPE}..."
    log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE" # -F forces
    echo "LOG: Formatting Swap partition (${SWAP_DEVICE_NODE})..."
    log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE" # -f forces
    echo "LOG: Partitions have been formatted."

    # Mount the filesystems
    echo "LOG: Mounting Root filesystem ($ROOT_DEVICE_NODE) on /mnt..."
    log_sudo_cmd mount "$ROOT_DEVICE_NODE" /mnt
    # Verify mount
    mounted_root_device=$(findmnt -n -o SOURCE --target /mnt || echo "none_found_for_root")
    if ! mountpoint -q /mnt || [[ "$mounted_root_device" != "$ROOT_DEVICE_NODE" ]]; then
        echo "ERROR: Failed to mount root partition ($ROOT_DEVICE_NODE) to /mnt, or mounted device is incorrect ($mounted_root_device)."
        exit 1
    fi
    echo "LOG: Root filesystem ($mounted_root_device) mounted on /mnt."

    log_sudo_cmd mkdir -p /mnt/boot
    echo "LOG: Mounting EFI partition ($EFI_DEVICE_NODE) on /mnt/boot..."
    log_sudo_cmd mount "$EFI_DEVICE_NODE" /mnt/boot
    # Verify mount
    mounted_efi_device=$(findmnt -n -o SOURCE --target /mnt/boot || echo "none_found_for_efi")
    if ! mountpoint -q /mnt/boot || [[ "$mounted_efi_device" != "$EFI_DEVICE_NODE" ]]; then
        echo "ERROR: Failed to mount EFI partition ($EFI_DEVICE_NODE) to /mnt/boot, or mounted device is incorrect ($mounted_efi_device)."
        exit 1
    fi
    echo "LOG: EFI partition ($mounted_efi_device) mounted on /mnt/boot."

    # Activate swap
    echo "LOG: Activating swap on $SWAP_DEVICE_NODE..."
    log_sudo_cmd swapon "$SWAP_DEVICE_NODE"
    echo "LOG: Filesystems mounted and swap activated."

    # Display final mounted layout for this stage
    echo "LOG: Final mounted filesystem layout on ${TARGET_DISK} for NixOS installation:"
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK"
    echo "LOG: Filesystem disk space usage for /mnt and /mnt/boot:"
    df -h /mnt /mnt/boot

} || { # This block executes if any command in the { ... } group above fails (due to set -e)
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERROR: A critical error occurred during disk operations in Step 2."
    echo "       Attempting to clean up mounts and swap..."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    # Attempt to clean up mounts and swap, suppressing errors as these are best-effort
    if mountpoint -q /mnt/boot; then sudo umount -lf /mnt/boot &>/dev/null || true; echo "LOG: (Cleanup) Unmounted /mnt/boot"; fi
    if mountpoint -q /mnt; then sudo umount -lf /mnt &>/dev/null || true; echo "LOG: (Cleanup) Unmounted /mnt"; fi
    if [[ -n "$SWAP_DEVICE_NODE" && -e "$SWAP_DEVICE_NODE" ]]; then
        sudo swapoff "$SWAP_DEVICE_NODE" &>/dev/null || true; echo "LOG: (Cleanup) Swapped off $SWAP_DEVICE_NODE"
    elif [[ -n "$SWAP_PART_NAME" ]]; then # Fallback to label if node var not set
        sudo swapoff -L "$SWAP_PART_NAME" &>/dev/null || true; echo "LOG: (Cleanup) Swapped off by label $SWAP_PART_NAME"
    else # General swapoff as last resort
        sudo swapoff -a &>/dev/null || true; echo "LOG: (Cleanup) Swapped off all devices"
    fi
    echo "ERROR: Disk operations failed. Examine logs above for details. You may need to manually clean up the target disk: ${TARGET_DISK}."
    exit 1 # Exit the script with an error code
}
# If the script reaches here, the { ... } disk operations block succeeded.
echo "LOG: Disk operations (partitioning, formatting, mounting) completed successfully."
echo "--------------------------------------------------------------------"
echo ""
echo "INFO: Current partition layout on ${TARGET_DISK} and final mount points for NixOS installation:"
sudo lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT,PARTLABEL,PTTYPE,PARTTYPE "$TARGET_DISK" # Show again for user review
echo ""
echo "INFO: Filesystem usage for /mnt and /mnt/boot:"
sudo df -h /mnt /mnt/boot # Show usage
echo ""
confirm "Disk partitioning, formatting, and mounting complete. Please review the layout above. Continue to generate NixOS module files?" "Y"
echo "--------------------------------------------------------------------"

# --- 3. Generate hardware-configuration.nix ---
echo "Step 3: Generating NixOS hardware configuration (hardware-configuration.nix)..."
# This command writes to /mnt/etc/nixos/hardware-configuration.nix
log_sudo_cmd nixos-generate-config --root /mnt
echo "LOG: hardware-configuration.nix generated at ${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix."

# Remove the base configuration.nix generated by nixos-generate-config, as we use a flake.
if [ -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix" ]; then
    echo "LOG: Removing the generated base ${TARGET_NIXOS_CONFIG_DIR}/configuration.nix as it is not used by this Flake setup."
    log_sudo_cmd rm -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"
fi
echo "--------------------------------------------------------------------"

# --- 4. Generate Flake and Custom Module Files ---
echo "Step 4: Generating Flake and copying custom NixOS module files..."
# Ensure the target NixOS configuration directory exists (should be created by nixos-generate-config)
log_sudo_cmd mkdir -p "${TARGET_NIXOS_CONFIG_DIR}"
echo "LOG: Ensured ${TARGET_NIXOS_CONFIG_DIR} exists."

# --- Part 1: Copy all .nix files (except flake.nix.template, hardware-configuration.nix) from templates to target ---
echo "LOG: Copying .nix module files from ${TEMPLATE_DIR} to ${TARGET_NIXOS_CONFIG_DIR}..."
# Initialize a flag to track if any files were copied
copied_any_modules=false
for nix_source_file in "${TEMPLATE_DIR}"/*.nix; do
    if [ -f "$nix_source_file" ]; then # Check if it's a file
        nix_filename=$(basename "$nix_source_file")
        # Skip copying flake.nix.template (it's a template) and hardware-configuration.nix (it's generated)
        if [[ "$nix_filename" == "flake.nix.template" || "$nix_filename" == "hardware-configuration.nix" ]]; then
            echo "LOG: Skipping special file: $nix_filename"
            continue
        fi
        dest_path="${TARGET_NIXOS_CONFIG_DIR}/${nix_filename}"
        echo "LOG: Copying $nix_filename to $dest_path..."
        # Copying requires sudo as target is in /mnt
        if sudo cp "$nix_source_file" "$dest_path"; then
            sudo chmod 644 "$dest_path" # Set reasonable permissions
            echo "LOG: ${nix_filename} copied successfully."
            copied_any_modules=true
        else
            echo "ERROR: Failed to copy ${nix_filename} to ${dest_path}."
            exit 1 # Critical error, cannot proceed
        fi
    fi
done
if ! $copied_any_modules; then
    echo "LOG: No additional .nix module files found in ${TEMPLATE_DIR} to copy (or only special files were present)."
fi
echo "LOG: Finished copying .nix module files."

# --- Part 2: Generate the list of NixOS module imports ---
echo "LOG: Generating dynamic NixOS module import list..."
declare -a nixos_module_imports_array=() 
# Use find to list .nix files in TARGET_NIXOS_CONFIG_DIR that should be imported.
# Exclude flake.nix itself and home-manager-user.nix (if handled separately).
# hardware-configuration.nix should always be imported.
while IFS= read -r -d $'\0' module_file_path_in_target; do
    module_filename_in_target=$(basename "$module_file_path_in_target")
    # Exclude files that are not meant to be in the main system imports list for the flake
    if [[ "$module_filename_in_target" == "flake.nix" || \
          "$module_filename_in_target" == "home-manager-user.nix" ]]; then # Add more exclusions if needed
        continue
    fi
    # hardware-configuration.nix is special, ensure it's included
    if [[ "$module_filename_in_target" == "hardware-configuration.nix" ]]; then
        # Ensure it's only added once, handled below
        continue
    fi
    nixos_module_imports_array+=("        ./${module_filename_in_target}") # 8 spaces for indentation
done < <(sudo find "$TARGET_NIXOS_CONFIG_DIR" -maxdepth 1 -type f -name "*.nix" -print0)

# Always add hardware-configuration.nix to the imports if it exists
if [ -f "${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix" ]; then
    nixos_module_imports_array+=("        ./hardware-configuration.nix")
else
    echo "WARN: hardware-configuration.nix not found in ${TARGET_NIXOS_CONFIG_DIR}. This is unusual after nixos-generate-config."
fi

# Join the array elements into a single string with newlines
generated_nixos_module_imports_string="" 
if [ ${#nixos_module_imports_array[@]} -gt 0 ]; then
    # Deduplicate (in case hardware-configuration.nix was found by find and added again)
    # This is a bit tricky with array elements containing paths/newlines if not careful.
    # A simple sort | uniq can work if order doesn't matter critically.
    # For now, assuming `find` doesn't list hardware-configuration.nix if it was already skipped.
    # The above logic tries to add it once. If find also lists it, it will be there twice.
    # Better to build the list carefully.
    # Let's rebuild the array ensuring hardware-configuration.nix is last and unique.
    
    declare -a final_imports_array=()
    has_hw_config=false
    for item in "${nixos_module_imports_array[@]}"; do
        if [[ "$item" == *"./hardware-configuration.nix"* ]]; then
            has_hw_config=true
        else
            final_imports_array+=("$item")
        fi
    done
    if $has_hw_config; then
        final_imports_array+=("        ./hardware-configuration.nix") # Add it at the end
    fi
    # Remove duplicates from final_imports_array
    # This is a common way to deduplicate an array in bash
    # Read the unique sorted lines back into the array
    # However, this might change order. Simple approach for now:
    # The previous find was on TEMPLATE_DIR, not TARGET_NIXOS_CONFIG_DIR.
    # The logic for generating this list has been simplified.
    # It should now only contain modules from TEMPLATE_DIR (excluding special ones) + hardware-configuration.nix.

    printf -v generated_nixos_module_imports_string '%s\n' "${nixos_module_imports_array[@]}" # Using original array for now
    generated_nixos_module_imports_string=${generated_nixos_module_imports_string%?} # Remove trailing newline
fi


echo "LOG: Generated module import block for flake.nix:"
echo -e "------ Start of Module Imports ------\n${generated_nixos_module_imports_string}\n------- End of Module Imports -------"


# --- Part 3: Generate flake.nix from template and insert dynamic module list ---
FLAKE_TEMPLATE_BASENAME="flake.nix.template"
FLAKE_OUTPUT_BASENAME="flake.nix"

# Ensure template directory exists
if [[ ! -d "$TEMPLATE_DIR" ]]; then
    echo "ERROR: Template directory '$TEMPLATE_DIR' not found. Cannot generate flake.nix."
    exit 1
fi

# Call the function to generate flake.nix, passing the generated module string
if ! generate_flake_with_modules "$FLAKE_TEMPLATE_BASENAME" "$FLAKE_OUTPUT_BASENAME" "${generated_nixos_module_imports_string}"; then
    echo "ERROR: Failed to generate comprehensive ${FLAKE_OUTPUT_BASENAME}. Aborting installation."
    exit 1 # Exit if flake generation fails
fi

echo "LOG: All NixOS configuration files processed and placed in ${TARGET_NIXOS_CONFIG_DIR}/."
echo "--------------------------------------------------------------------"

# --- 5. Install NixOS ---
echo "Step 5: Installing NixOS using the Flake configuration..."
echo "This process will take a significant amount of time. Please be patient."
echo "You will see a lot of build output (this is normal)."
echo ""
confirm "Proceed with NixOS installation using the generated flake at ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}?" "Y" # Default to Yes

echo "LOG: Starting nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"
# The output of nixos-install itself will go to console because log_sudo_cmd echoes the command,
# and then executes `sudo nixos-install ...` whose output also goes to console.
if sudo nixos-install --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"; then # `set -e` will handle failure
    echo ""
    echo "--------------------------------------------------------------------"
    echo "NixOS installation completed successfully!"
    echo "Your new NixOS system has been installed."
    echo "It is recommended to:"
    echo "  1. Remove the installation media (USB drive)."
    echo "  2. Reboot the system."
    echo ""
    read -r -p "Please REMOVE the installation media NOW, then press ENTER to reboot the system: " _
    echo "LOG: User pressed Enter to reboot after removing media."
    sudo reboot
else
    # This else block will only be reached if `set -e` is NOT active and nixos-install fails.
    # With `set -e`, the script would have exited on nixos-install failure.
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ERROR: NixOS installation failed. Check the output above for details."
    echo "       You may also find logs in /mnt/var/log/nixos-install.log if the"
    echo "       installation process reached that stage."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 1
fi

# If script somehow reaches here after nixos-install success (e.g., user Ctrl+C before reboot)
echo "LOG: End of script reached. If system did not reboot, please do so manually after removing installation media."
exit 0
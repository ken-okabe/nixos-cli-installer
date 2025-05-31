#!/usr/bin/env bash

# === Enhanced NixOS Flake-based Installation Script ===
set -euo pipefail # Exit on error, undefined vars, pipe failures

# === Global Variables ===
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
TARGET_NIXOS_CONFIG_DIR="/mnt/etc/nixos"
LOG_FILE="/tmp/nixos-install-$(date +%s).log"

# Partition configuration
SWAP_SIZE_GB="16"
DEFAULT_EFI_SIZE_MiB="512"
EFI_PART_NAME="EFI"
SWAP_PART_NAME="SWAP"
ROOT_PART_NAME="ROOT_NIXOS"
DEFAULT_ROOT_FS_TYPE="ext4"

# Device nodes (set during partitioning)
EFI_DEVICE_NODE=""
ROOT_DEVICE_NODE=""
SWAP_DEVICE_NODE=""

# User configuration variables
NIXOS_USERNAME=""
PASSWORD_HASH=""
GIT_USERNAME=""
GIT_USEREMAIL=""
HOSTNAME=""
TARGET_DISK=""

# === Logging Functions ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | sudo tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | sudo tee -a "$LOG_FILE" >&2
}

log_cmd() {
    log "CMD: $*" 
    local status
    # Execute command, pipe its stdout/stderr to sudo tee -a for logging.
    # >/dev/null on tee prevents it from echoing to console (already logged by log "CMD: ...").
    # Subshell with pipefail ensures we get the status of the command, not tee.
    if ! (set -o pipefail; "$@" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null); then
        status=$? 
        log_error "Command failed with exit code $status: $*"
        return 1
    fi
    return 0
}

log_sudo_cmd() {
    log "SUDO CMD: $*" 
    local status
    if ! (set -o pipefail; sudo "$@" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null); then
        status=$? 
        log_error "Sudo command failed with exit code $status: $*"
        return 1
    fi
    return 0
}

# === Dependency Checking ===
check_dependencies() {
    log "Checking required dependencies..."
    
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        log_error "Template directory not found: $TEMPLATE_DIR"
        exit 1
    fi
    
    local deps=("mkpasswd" "sfdisk" "nixos-generate-config" "nixos-install" "lsblk" "findmnt" "mktemp" "blkid" "udevadm" "tee" "awk" "sed" "grep" "tr" "sync" "partprobe" "blockdev" "mountpoint" "swapon" "swapoff" "mkfs.vfat" "mkswap")
    deps+=("mkfs.$DEFAULT_ROOT_FS_TYPE")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please ensure the NixOS installation environment has these tools, or install them if possible." >&2
        exit 1
    fi
    
    log "All dependencies satisfied."
}

# === Confirmation Function ===
confirm() {
    local question="$1"
    local default_response_char="$2"
    local prompt_display=""

    if [[ "$default_response_char" == "Y" ]]; then
        prompt_display="[Y/n]"
    elif [[ "$default_response_char" == "N" ]]; then
        prompt_display="[y/N]"
    else
        log_error "confirm function called with invalid default: '$default_response_char'"
        prompt_display="[y/N]" 
        default_response_char="N"
    fi

    while true; do
        read -r -p "${question} ${prompt_display}: " response >&2
        local response_lower
        response_lower=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response_lower" in
            y|yes)
                return 0
                ;;
            n|no)
                echo "You selected 'No'. For critical choices, this may abort or re-prompt. Press Ctrl+C to abort script if stuck." >&2
                ;;
            "") 
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0
                else 
                    echo "Default is 'No'. For critical choices, this may abort or re-prompt. Press Ctrl+C to abort script if stuck." >&2
                fi
                ;;
            *)
                echo "Invalid input. Please type 'y', 'n', or press Enter for default." >&2
                ;;
        esac
    done
}


# === String Escaping Functions ===
escape_for_sed() {
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g' -e 's/[\[.*^$(){}+?|\\]/\\&/g'
}

# === Progress Indicator ===
show_progress() {
    local pid=$1
    local msg="$2"
    
    log "Starting background process '$msg' with PID $pid"
    while kill -0 "$pid" 2>/dev/null; do 
        for i in / - \\ \|; do
            printf '\r%s %s' "$msg" "$i" >&2 
            sleep 0.25
        done
    done
    printf '\r%s... Done!                     \n' "$msg" >&2 
    log "Background process '$msg' with PID $pid presumed completed."
}


# === Cleanup Function ===
cleanup_on_error() {
    log_error "An error occurred at line $LINENO (command: $BASH_COMMAND). Performing cleanup..."
    
    if mountpoint -q /mnt/boot 2>/dev/null; then
        log "Attempting to unmount /mnt/boot during cleanup."
        sudo umount /mnt/boot || log_error "Failed to unmount /mnt/boot during cleanup."
    fi
    
    if mountpoint -q /mnt 2>/dev/null; then
        log "Attempting to unmount /mnt during cleanup."
        sudo umount /mnt || log_error "Failed to unmount /mnt during cleanup."
    fi
    
    if [[ -n "$SWAP_DEVICE_NODE" && -e "$SWAP_DEVICE_NODE" ]]; then 
        log "Attempting to swapoff $SWAP_DEVICE_NODE during cleanup."
        sudo swapoff "$SWAP_DEVICE_NODE" 2>/dev/null || true 
    fi
    
    log "Attempting to swapoff all devices during cleanup."
    sudo swapoff -a 2>/dev/null || true 
    
    log "Cleanup attempt completed."
    echo "An error occurred. Check the log file for details: $LOG_FILE" >&2
}

trap cleanup_on_error ERR INT TERM

# === Disk Management Functions ===
show_available_disks() {
    echo "Available block devices (disks only):" >&2
    lsblk -dpno NAME,SIZE,MODEL,TYPE | grep -E "disk$" | while IFS= read -r line; do
        local disk_path
        disk_path=$(echo "$line" | awk '{print $1}')
        if [[ -b "$disk_path" ]]; then
            echo "  $line" >&2
        fi
    done
}

prepare_mount_points() {
    log "Checking and preparing mount points (/mnt, /mnt/boot)..."
    local mount_points=("/mnt/boot" "/mnt") 
    
    for mp in "${mount_points[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            local current_device
            current_device=$(findmnt -n -o SOURCE --target "$mp")
            log "Mount point '$mp' is currently mounted by device '$current_device'"
            
            if [[ "$current_device" == "$TARGET_DISK"* ]]; then
                 log "Device '$current_device' appears to be part of the target disk '$TARGET_DISK'."
                 log "Unmounting '$current_device' from '$mp'..."
                 sudo umount -f "$mp" || { log_error "Failed to unmount '$mp'. Exiting."; exit 1; }
            else
                if confirm "Mount point '$mp' is in use by '$current_device' (NOT the target disk '$TARGET_DISK'). Unmount it to proceed?" "N"; then
                    sudo umount -f "$mp" || {
                        log_error "Failed to unmount '$mp'. Please unmount manually and restart script. Exiting."
                        exit 1
                    }
                else
                    log_error "Cannot proceed with '$mp' in use by a non-target device. Exiting."
                    exit 1
                fi
            fi
        fi
    done
    log "Mount points checked and prepared."
}

calculate_partitions() {
    log "Calculating partition sizes for disk $TARGET_DISK..."
    local total_bytes
    total_bytes=$(sudo blockdev --getsize64 "$TARGET_DISK")
    
    if ! [[ "$total_bytes" =~ ^[0-9]+$ ]] || [ "$total_bytes" -le 0 ]; then
        log_error "Could not determine a valid disk size for $TARGET_DISK (got '$total_bytes' bytes). Exiting."
        exit 1
    fi
    
    local total_mib=$((total_bytes / 1024 / 1024))
    log "Total disk size: $total_mib MiB."

    local efi_start_mib=1 
    local efi_size_mib=$DEFAULT_EFI_SIZE_MiB
    local swap_size_req_mib=$((SWAP_SIZE_GB * 1024))
    local min_root_size_mib=20480 

    if [ $((efi_start_mib + efi_size_mib + swap_size_req_mib + min_root_size_mib)) -gt "$total_mib" ]; then
        log "Disk is potentially too small ($total_mib MiB) for requested EFI ($efi_size_mib MiB), Swap ($swap_size_req_mib MiB), and minimum Root ($min_root_size_mib MiB)."
        if [ "$efi_size_mib" -eq "$DEFAULT_EFI_SIZE_MiB" ] && [ "$DEFAULT_EFI_SIZE_MiB" -gt 256 ]; then
            log "Attempting to reduce EFI size to 256MiB..."
            efi_size_mib=256
            if [ $((efi_start_mib + efi_size_mib + swap_size_req_mib + min_root_size_mib)) -gt "$total_mib" ]; then
                 log_error "Disk still too small even with reduced EFI size (256MiB). Exiting."
                 exit 1
            fi
            log "Reduced EFI size to ${efi_size_mib}MiB."
        else
            log_error "Cannot reduce EFI size further or not enough space. Exiting."
            exit 1
        fi
    fi

    local root_start_mib=$((efi_start_mib + efi_size_mib))
    local swap_start_candidate=$((total_mib - swap_size_req_mib))

    if [ "$swap_start_candidate" -le "$root_start_mib" ]; then
        log_error "Not enough space for root partition after allocating EFI, or Swap is too large. Root starts at $root_start_mib, Swap would start at $swap_start_candidate (calculated from end). Exiting."
        exit 1
    fi
    
    local swap_size_actual_mib=$swap_size_req_mib
    
    if [ $((total_mib - root_start_mib)) -lt "$swap_size_req_mib" ]; then
        log "Warning: Requested swap size ($swap_size_req_mib MiB) is larger than available after EFI. Reducing swap size."
        swap_size_actual_mib=$((total_mib - root_start_mib - 1)) 
        if [ "$swap_size_actual_mib" -lt 512 ]; then 
            log_error "Calculated swap size ($swap_size_actual_mib MiB) is too small. Check disk space or SWAP_SIZE_GB. Exiting."
            exit 1
        fi
    fi
    
    local swap_start_mib=$((total_mib - swap_size_actual_mib))
    local root_size_mib=$((swap_start_mib - root_start_mib))
    
    if [ "$root_size_mib" -lt "$min_root_size_mib" ]; then
        log_error "Calculated root partition size (${root_size_mib}MiB) is less than minimum required (${min_root_size_mib}MiB). Exiting."
        exit 1
    fi
    
    log "Calculated partition layout (MiB):"
    log "  EFI:  start=${efi_start_mib}, size=${efi_size_mib}"
    log "  Root: start=${root_start_mib}, size=${root_size_mib}"
    log "  Swap: start=${swap_start_mib}, size=${swap_size_actual_mib}"
    
    EFI_START_MIB_CALC=$efi_start_mib
    EFI_SIZE_MIB_CALC=$efi_size_mib
    ROOT_START_MIB_CALC=$root_start_mib
    ROOT_SIZE_MIB_CALC=$root_size_mib
    SWAP_START_MIB_CALC=$swap_start_mib
    SWAP_SIZE_MIB_CALC=$swap_size_actual_mib
}


create_partitions() {
    log "Creating partition scheme on $TARGET_DISK..."
    
    local part_prefix="" 
    if [[ "$TARGET_DISK" == /dev/nvme* || "$TARGET_DISK" == /dev/loop* ]]; then
        part_prefix="p" 
    fi
    EFI_DEVICE_NODE="${TARGET_DISK}${part_prefix}1"
    ROOT_DEVICE_NODE="${TARGET_DISK}${part_prefix}2"
    SWAP_DEVICE_NODE="${TARGET_DISK}${part_prefix}3"
    
    local efi_type_guid="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" 
    local root_type_guid="0FC63DAF-8483-4772-8E79-3D69D8477DE4" 
    local swap_type_guid="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" 
    
    local sfdisk_input
    sfdisk_input=$(cat <<EOF
label: gpt
${EFI_DEVICE_NODE} : start=${EFI_START_MIB_CALC}M, size=${EFI_SIZE_MIB_CALC}M, type=${efi_type_guid}, name="${EFI_PART_NAME}"
${ROOT_DEVICE_NODE} : start=${ROOT_START_MIB_CALC}M, size=${ROOT_SIZE_MIB_CALC}M, type=${root_type_guid}, name="${ROOT_PART_NAME}"
${SWAP_DEVICE_NODE} : start=${SWAP_START_MIB_CALC}M, size=${SWAP_SIZE_MIB_CALC}M, type=${swap_type_guid}, name="${SWAP_PART_NAME}"
EOF
) 
    
    log "Applying partition scheme with sfdisk. Details (input script follows):"
    echo -e "$sfdisk_input" | sudo tee -a "$LOG_FILE" >/dev/null
    
    local sfdisk_status=0
    log "Executing sfdisk command..." 
    if ! (set -o pipefail; printf "%s" "$sfdisk_input" | sudo sfdisk \
        --wipe always \
        --wipe-partitions always \
        "$TARGET_DISK" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null); then
        sfdisk_status=$? 
        log_error "sfdisk command failed with exit code $sfdisk_status. Check log for sfdisk's direct output. Exiting."
        exit 1
    fi
    log "sfdisk command appears to have completed."

    log "Informing kernel of partition changes..."
    # Use log_cmd for sync as it's a non-sudo command whose output isn't critical but should be logged
    log_cmd sync 

    if ! log_sudo_cmd partprobe "$TARGET_DISK"; then
        log_error "partprobe $TARGET_DISK returned non-zero (see log for details). Attempting blockdev..."
    fi
    if ! log_sudo_cmd blockdev --rereadpt "$TARGET_DISK"; then
        log_error "blockdev --rereadpt $TARGET_DISK also returned non-zero (see log for details). Udev might still pick up changes."
    fi
    
    log "Waiting for udev to settle partition changes..."
    log_sudo_cmd udevadm settle
    sleep 3 
    
    log "Partition scheme applied. Verifying partitions on $TARGET_DISK:"
    if ! log_sudo_cmd sfdisk -l "$TARGET_DISK"; then
        log_error "Failed to list partitions with 'sfdisk -l' after creation (see log). Continuing cautiously..."
    fi
}


format_partitions() {
    log "Formatting partitions..."
    
    local max_wait_seconds=20 
    local current_wait=0
    log "Waiting up to $max_wait_seconds seconds for device nodes: $EFI_DEVICE_NODE, $ROOT_DEVICE_NODE, $SWAP_DEVICE_NODE"
    
    while [[ (! -b "$EFI_DEVICE_NODE" || ! -b "$ROOT_DEVICE_NODE" || ! -b "$SWAP_DEVICE_NODE") && "$current_wait" -lt "$max_wait_seconds" ]]; do
        log "Device nodes not all available yet (waited $current_wait s). Triggering udev and waiting..."
        # udevadm trigger/settle are sudo commands
        log_sudo_cmd udevadm trigger 
        log_sudo_cmd udevadm settle   
        sleep 1
        current_wait=$((current_wait + 1))
    done
    
    if [[ ! -b "$EFI_DEVICE_NODE" ]]; then log_error "$EFI_DEVICE_NODE is not a block device after wait!"; fi
    if [[ ! -b "$ROOT_DEVICE_NODE" ]]; then log_error "$ROOT_DEVICE_NODE is not a block device after wait!"; fi
    if [[ ! -b "$SWAP_DEVICE_NODE" ]]; then log_error "$SWAP_DEVICE_NODE is not a block device after wait!"; fi

    if [[ ! -b "$EFI_DEVICE_NODE" || ! -b "$ROOT_DEVICE_NODE" || ! -b "$SWAP_DEVICE_NODE" ]]; then
        log_error "One or more partition device nodes did not become available after $max_wait_seconds seconds. Exiting."
        (set -o pipefail; lsblk "$TARGET_DISK" -o NAME,PATH,TYPE,SIZE 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null)
        exit 1
    fi
    log "All partition device nodes are available."
    
    log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"
    log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE" 
    log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE" 
    
    log "Partitions formatted. Verifying UUIDs and Labels post-formatting:"
    (set -o pipefail; sudo blkid "$EFI_DEVICE_NODE" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null)
    (set -o pipefail; sudo blkid "$ROOT_DEVICE_NODE" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null)
    (set -o pipefail; sudo blkid "$SWAP_DEVICE_NODE" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null)
    
    log "Partition formatting completed successfully."
}

mount_filesystems() {
    log "Mounting filesystems..."
    
    log "Mounting Root partition $ROOT_DEVICE_NODE on /mnt"
    if ! log_sudo_cmd mount "$ROOT_DEVICE_NODE" /mnt; then
        log_error "Failed to mount root filesystem $ROOT_DEVICE_NODE on /mnt via log_sudo_cmd. Exiting."
        exit 1
    fi
    if ! mountpoint -q /mnt; then 
        log_error "Verification failed: /mnt is not a mountpoint after mount command. Exiting."
        exit 1
    fi
    
    log_sudo_cmd mkdir -p /mnt/boot

    log "Mounting EFI partition $EFI_DEVICE_NODE on /mnt/boot"
    if ! log_sudo_cmd mount "$EFI_DEVICE_NODE" /mnt/boot; then
        log_error "Failed to mount EFI filesystem $EFI_DEVICE_NODE on /mnt/boot via log_sudo_cmd. Exiting."
        sudo umount /mnt 2>/dev/null || true 
        exit 1
    fi
     if ! mountpoint -q /mnt/boot; then 
        log_error "Verification failed: /mnt/boot is not a mountpoint after mount command. Exiting."
        sudo umount /mnt 2>/dev/null || true 
        exit 1
    fi
    
    log "Enabling swap on $SWAP_DEVICE_NODE"
    log_sudo_cmd swapon "$SWAP_DEVICE_NODE"
    
    log "Filesystems mounted and swap enabled successfully."
    log "Current filesystem layout on $TARGET_DISK (output to console and log):"
    # MODIFIED: Removed >/dev/null to allow tee to output to console as well
    (set -o pipefail; sudo lsblk -fpo NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,PARTUUID "$TARGET_DISK" 2>&1 | sudo tee -a "$LOG_FILE")
}
  

# === Configuration Generation Functions ===
generate_flake_with_modules() {
    local template_file="$1"    
    local output_file="$2"      
    local module_imports_str="$3" 
    local template_path="${TEMPLATE_DIR}/${template_file}"
    local output_path="${TARGET_NIXOS_CONFIG_DIR}/${output_file}"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template file for $output_file not found: $template_path." # Removed Exiting, will be handled by return 1
        return 1
    fi
    
    log "Generating $output_file from template $template_path..."
    
    local temp_processed_vars temp_final_output
    temp_processed_vars=$(mktemp)
    temp_final_output=$(mktemp)
    trap "rm -f '$temp_processed_vars' '$temp_final_output' 2>/dev/null" RETURN # Cleanup temp files when function returns

    sed \
        -e "s/__NIXOS_USERNAME__/$(escape_for_sed "$NIXOS_USERNAME")/g" \
        -e "s/__PASSWORD_HASH__/$(escape_for_sed "$PASSWORD_HASH")/g" \
        -e "s/__GIT_USERNAME__/$(escape_for_sed "$GIT_USERNAME")/g" \
        -e "s/__GIT_USEREMAIL__/$(escape_for_sed "$GIT_USEREMAIL")/g" \
        -e "s/__HOSTNAME__/$(escape_for_sed "$HOSTNAME")/g" \
        -e "s/__TARGET_DISK_FOR_GRUB__/$(escape_for_sed "$TARGET_DISK")/g" \
        "$template_path" > "$temp_processed_vars"

    local placeholder="#__NIXOS_MODULE_IMPORTS_PLACEHOLDER__#"
    if grep -qF "$placeholder" "$temp_processed_vars"; then
        awk -v imports="$module_imports_str" -v placeholder="$placeholder" '
            {
                if (index($0, placeholder)) {
                    print imports
                } else {
                    print $0
                }
            }
        ' "$temp_processed_vars" > "$temp_final_output"
        log "Module imports injected into $output_file template."
    else
        cp "$temp_processed_vars" "$temp_final_output" 
        log "No module import placeholder '$placeholder' found in $template_file. Using variable-substituted content directly."
    fi
    
    log "Installing generated file to $output_path"
    if sudo mv "$temp_final_output" "$output_path" && sudo chmod 644 "$output_path"; then
        log "$output_file generated and installed successfully at $output_path."
        # temp_final_output was moved, temp_processed_vars will be cleaned by trap
        return 0
    else
        log_error "Failed to install $output_file to $output_path or chmod failed. Review permissions."
        # Temp files will be cleaned by trap
        return 1
    fi
}


copy_nix_modules() {
    log "Copying custom NixOS module files from $TEMPLATE_DIR to $TARGET_NIXOS_CONFIG_DIR..."
    
    local files_to_copy
    files_to_copy=$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*.nix" -type f \
                    -not -name "flake.nix.template" \
                    -not -name "hardware-configuration.nix")

    if [ -z "$files_to_copy" ]; then
        log "No additional custom .nix modules found in $TEMPLATE_DIR to copy."
        return
    fi

    echo "$files_to_copy" | while IFS= read -r nix_file_path; do
        local filename
        filename=$(basename "$nix_file_path")
        local dest_path="${TARGET_NIXOS_CONFIG_DIR}/${filename}"
        
        log "Copying $filename to $dest_path..."
        if ! log_sudo_cmd cp "$nix_file_path" "$dest_path" || ! log_sudo_cmd chmod 644 "$dest_path"; then
            log_error "Failed to copy or chmod $filename to $dest_path. Exiting." # log_sudo_cmd already logs details
            exit 1 
        fi
    done
    log "Custom NixOS module files copied."
}


generate_module_imports() {
    local imports_array=()
    local copied_module_files
    copied_module_files=$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*.nix" -type f \
                            -not -name "flake.nix.template" \
                            -not -name "hardware-configuration.nix")

    if [ -n "$copied_module_files" ]; then
        echo "$copied_module_files" | while IFS= read -r module_path; do
            local filename
            filename=$(basename "$module_path")
            imports_array+=("      ./${filename}") 
        done
    fi
    
    imports_array+=("      ./hardware-configuration.nix")

    local import_string=""
    if [[ ${#imports_array[@]} -gt 0 ]]; then
        printf -v import_string '%s\n' "${imports_array[@]}"
        import_string=${import_string%?} 
    fi
    
    echo "$import_string" 
}


# === User Input Functions ===
get_user_input() {
    log "Gathering user configuration..."
    
    show_available_disks 
    echo "" >&2 
    
    while true; do
        read -r -p "Enter target disk (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK >&2
        if [[ -b "$TARGET_DISK" ]]; then
            if confirm "You selected '$TARGET_DISK'. ALL DATA ON THIS DISK WILL BE ERASED! This is irreversible. Are you absolutely sure?" "N"; then
                break 
            else
                log "User declined disk selection $TARGET_DISK. Asking again."
            fi
        else
            echo "Error: '$TARGET_DISK' is not a valid block device or does not exist. Please check the path." >&2
        fi
    done
    log "User confirmed target disk for installation: $TARGET_DISK"
    
    while [[ -z "$NIXOS_USERNAME" ]]; do
        read -r -p "Enter username for the primary NixOS user: " NIXOS_USERNAME >&2
        if ! [[ "$NIXOS_USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ && ${#NIXOS_USERNAME} -le 32 ]]; then
            echo "Invalid username. Use lowercase letters, numbers, underscores, hyphens. Start with letter/underscore. Max 32 chars." >&2
            NIXOS_USERNAME="" 
        fi
    done
    log "NixOS username set to: $NIXOS_USERNAME"
    
    while true; do
        read -r -s -p "Enter password for user '$NIXOS_USERNAME': " pass1 >&2
        echo "" >&2 
        read -r -s -p "Confirm password: " pass2 >&2
        echo "" >&2 
        
        if [[ -z "$pass1" ]]; then
            echo "Password cannot be empty. Please try again." >&2
            continue
        fi

        if [[ "$pass1" == "$pass2" ]]; then
            PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 --stdin) 
            if [[ -n "$PASSWORD_HASH" && "$PASSWORD_HASH" == \$6\$* ]]; then 
                log "Password hash generated successfully for user $NIXOS_USERNAME."
                break 
            else
                log_error "Failed to generate a valid password hash. mkpasswd output: '$PASSWORD_HASH'"
                echo "Password hash generation failed. Please try again. Ensure 'mkpasswd' (from shadow utils with --stdin support) is working." >&2
            fi
        else
            echo "Passwords do not match. Please try again." >&2
        fi
    done
    unset pass1 pass2 
    
    while [[ -z "$GIT_USERNAME" ]]; do
        read -r -p "Enter your Git username (for user's .gitconfig, e.g., 'Your Name'): " GIT_USERNAME >&2
    done
    log "Git username set to: $GIT_USERNAME"
    
    while [[ -z "$GIT_USEREMAIL" ]]; do
        read -r -p "Enter your Git email (for user's .gitconfig): " GIT_USEREMAIL >&2
         if ! [[ "$GIT_USEREMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then 
            echo "Invalid email address format. Please try again." >&2
            GIT_USEREMAIL="" 
        fi
    done
    log "Git email set to: $GIT_USEREMAIL"
    
    read -r -p "Enter hostname for the system (e.g., 'nixos-desktop', default: nixos): " HOSTNAME >&2
    HOSTNAME=${HOSTNAME:-nixos} 
    if ! [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo "Invalid hostname. Using 'nixos' as default." >&2
        HOSTNAME="nixos"
    fi
    log "Hostname set to: $HOSTNAME"
    
    echo "" >&2
    echo "--- Configuration Summary ---" >&2
    echo "  Target Disk:      $TARGET_DISK" >&2
    echo "  NixOS Username:   $NIXOS_USERNAME" >&2
    echo "  Git Username:     $GIT_USERNAME" >&2
    echo "  Git Email:        $GIT_USEREMAIL" >&2
    echo "  Hostname:         $HOSTNAME" >&2
    echo "  EFI Size (MiB):   $DEFAULT_EFI_SIZE_MiB (may be adjusted if disk is small)" >&2
    echo "  Swap Size (GiB):  $SWAP_SIZE_GB (may be adjusted if disk is small)" >&2
    echo "  Root FS Type:     $DEFAULT_ROOT_FS_TYPE" >&2
    echo "---------------------------" >&2
    echo "" >&2
    
    confirm "Proceed with installation using these settings?" "Y"
    log "User confirmed settings. Proceeding with partitioning."
}


# === Main Installation Functions ===
partition_and_format_disk() {
    log "Starting disk partitioning and formatting operations for $TARGET_DISK..."
    prepare_mount_points 
    calculate_partitions 
    log "Turning off any existing swap devices on the system..."
    log_sudo_cmd swapoff -a || log_error "swapoff -a returned non-zero (this can be ignored if no swap was active)." # Continue even if it fails
    create_partitions 
    format_partitions 
    mount_filesystems 
    log "Disk operations (partitioning, formatting, mounting) completed successfully."
}


generate_nixos_config() {
    log "Generating NixOS configuration files in $TARGET_NIXOS_CONFIG_DIR..."
    log "Running 'nixos-generate-config --root /mnt' to create hardware-configuration.nix..."
    if ! log_sudo_cmd nixos-generate-config --root /mnt; then
        # log_sudo_cmd already logs the specific error and exit code from nixos-generate-config
        log_error "Exiting due to nixos-generate-config failure."
        exit 1
    fi
    log "'nixos-generate-config' completed."

    local hw_conf_path="${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix"
    if sudo test -f "$hw_conf_path"; then
        log "Verifying generated $hw_conf_path content (key entries will be logged):"
        (
            echo "--- Relevant entries from $hw_conf_path ---"
            sudo grep -E 'fileSystems\."/"|fileSystems\."/boot"|boot\.loader\.(grub|systemd-boot)\.(device|enable|efiSupport|canTouchEfiVariables)|networking\.hostName|imports' "$hw_conf_path" || echo "No matching entries found by grep in $hw_conf_path."
            echo "--- End of $hw_conf_path excerpt ---"
        ) 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null 
    else
        log_error "$hw_conf_path NOT FOUND after nixos-generate-config execution! This is critical. Exiting."
        exit 1
    fi
    
    if sudo test -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"; then
        log "Removing default ${TARGET_NIXOS_CONFIG_DIR}/configuration.nix (will be replaced by flake structure)."
        if ! log_sudo_cmd rm -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"; then
             log_error "Failed to remove default configuration.nix. Continuing, but this might cause issues if it's not overwritten."
        fi
    fi
    
    log_sudo_cmd mkdir -p "$TARGET_NIXOS_CONFIG_DIR" 
    copy_nix_modules 
    
    log "Generating the string of module import statements for flake.nix..."
    local module_imports_str
    module_imports_str=$(generate_module_imports) 
    log "Module import statements for flake.nix will be:\n$module_imports_str"
    
    log "Generating main flake.nix from template..."
    if ! generate_flake_with_modules "flake.nix.template" "flake.nix" "$module_imports_str"; then
        log_error "Failed to generate flake.nix. Exiting." # generate_flake_with_modules logs details
        exit 1
    fi
    
    log "NixOS configuration generation process completed."
    log "IMPORTANT NOTE FOR THE USER:" # These are informational for the log
    log "  Ensure your flake.nix and custom modules in $TARGET_NIXOS_CONFIG_DIR"
    log "  correctly use 'hardware-configuration.nix' for filesystems/bootloader."
    log "  For EFI systems, ensure an EFI bootloader is enabled and configured."
}


install_nixos() {
    log "Starting NixOS installation phase..."
    echo "" >&2
    echo "The NixOS installation process will now begin." >&2
    echo "This may take a significant amount of time, depending on your internet connection and system speed." >&2
    echo "Please be patient. You can monitor progress details in the log file: $LOG_FILE" >&2
    echo "(e.g., run 'sudo tail -f $LOG_FILE' in another terminal)" >&2
    echo "" >&2
    
    if confirm "Proceed with NixOS installation using the generated configuration at '${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}'?" "Y"; then
        log "User confirmed. Preparing to run 'nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}'"
        
        ( set -o pipefail; sudo nixos-install --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null ) &
        local install_pid=$!
        log "nixos-install process started in background with PID $install_pid."
        
        show_progress $install_pid "Installing NixOS (PID: $install_pid)" 
        
        # MODIFIED: Simplified and corrected wait logic
        wait "$install_pid"
        local install_status=$? 

        if [ "$install_status" -eq 0 ]; then
            log "NixOS installation command (PID: $install_pid) completed successfully (exit status: 0)."
            # This is the primary success message logged before user-facing messages.
            log "NixOS installation phase appears to have completed successfully."

            echo "" >&2
            echo "======================================================================" >&2
            echo "      NixOS Installation Complete!                                  " >&2
            echo "======================================================================" >&2
            echo "" >&2
            echo "Your new NixOS system has been installed." >&2
            echo "  User account created:   $NIXOS_USERNAME" >&2
            echo "  Hostname:               $HOSTNAME" >&2
            echo "  Config files location:  $TARGET_NIXOS_CONFIG_DIR" >&2
            echo "  Full installation log:  $LOG_FILE" >&2
            echo "" >&2

            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "!!! IMPORTANT: Please REMOVE the NixOS installation media (USB drive) NOW. !!!" >&2
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            read -r -p "After removing the installation media, press ENTER to continue to the next step: " _ >&2
            log "User acknowledged USB media removal by pressing Enter."
            echo "" >&2

            while true; do
                read -r -p "What would you like to do next? (1: Reboot into NixOS, 2: Power off system) [1]: " action >&2
                action=${action:-1} 

                case "$action" in
                    1)
                        log "User chose to reboot."
                        echo "Rebooting the system into NixOS..." >&2
                        sudo reboot
                        exit 0 
                        ;;
                    2)
                        log "User chose to power off."
                        echo "Powering off the system..." >&2
                        sudo poweroff
                        exit 0 
                        ;;
                    *)
                        echo "Invalid selection. Please enter 1 for Reboot or 2 for Power off." >&2
                        ;;
                esac
            done
        else 
            # This block is now the single point of failure reporting for nixos-install
            log_error "NixOS installation command (PID: $install_pid) FAILED with exit status: $install_status."
            # The detailed error from nixos-install itself should be in $LOG_FILE (and potentially /mnt/var/log/nixos-install.log)

            echo "" >&2
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "!!! NixOS Installation FAILED. Please check the log file:          !!!" >&2
            echo "!!!   $LOG_FILE                                                    !!!"
            echo "!!! The actual error from nixos-install should be in this log.     !!!"
            echo "!!! You may also find more specific errors from nixos-install in:  !!!"
            echo "!!!   /mnt/var/log/nixos-install.log (if it was created on /mnt)   !!!"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "" >&2
            echo "Common reasons for failure include:" >&2
            echo "  - Network connectivity issues during package downloads." >&2
            echo "  - Errors in your custom NixOS configuration/flake (syntax, missing options, package build failures)." >&2
            echo "  - Insufficient disk space (check space on /mnt and for /nix/store within the chroot)." >&2
            echo "  - Hardware compatibility issues not addressed in configuration." >&2
            echo "  - Bootloader installation problems." >&2
            exit 1 
        fi
    else
      log "NixOS installation process aborted by user before starting 'nixos-install'."
      echo "NixOS Installation aborted by user." >&2
    fi
}


# === Main Script Execution ===
main() {
    if [[ $EUID -ne 0 ]]; then 
        if ! sudo -n true 2>/dev/null; then 
            echo "This script requires sudo privileges. Attempting to acquire..." >&2
            if ! sudo true; then 
                echo "Failed to acquire sudo privileges. Please run with sudo or ensure passwordless sudo is configured. Exiting." >&2
                exit 1
            fi
            echo "Sudo privileges acquired." >&2
        else
             log "Script not run as root, but passwordless sudo seems available."
        fi
    else
        log "Script is running as root."
    fi

    echo "Initializing NixOS Installation Script. Log file: $LOG_FILE" | sudo tee "$LOG_FILE" >/dev/null 
    
    echo "======================================================================" >&2
    echo "      Enhanced NixOS Flake-based Installation Script                  " >&2
    echo "======================================================================" >&2
    echo "" >&2
    echo "WARNING: This script will attempt to ERASE ALL DATA on the disk you select!" >&2
    echo "         Please ensure you have backed up any important data from that disk." >&2
    echo "         You are solely responsible for the disk selection and data loss." >&2
    echo "" >&2
    echo "Installation progress and details will be logged to: $LOG_FILE" >&2
    echo "It is recommended to monitor this log in another terminal if possible:" >&2
    echo "  sudo tail -f $LOG_FILE" >&2
    echo "" >&2
    
    if ! confirm "Do you understand the risks and accept full responsibility for ALL ACTIONS this script will perform, including potential data loss on the selected disk?" "N"; then
        log "Installation aborted by user at initial responsibility confirmation."
        echo "Installation aborted by user. No changes were made." >&2
        exit 0 
    fi
    
    log "User accepted responsibility. Starting NixOS installation process..."
    log "Script execution started at: $(date)"
    log "Script directory: $SCRIPT_DIR"
    log "Template directory: $TEMPLATE_DIR"
    
    check_dependencies        
    get_user_input            
    partition_and_format_disk 
    generate_nixos_config     
    install_nixos             

    log "Main script execution sequence finished successfully (or user chose not to reboot/poweroff yet)."
}

main "$@"
exit 0
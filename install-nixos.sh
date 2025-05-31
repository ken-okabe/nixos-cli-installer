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
    # Log the command being run, then execute it, redirecting its stdout/stderr to the log file.
    log "CMD: $*"
    # Ensure the command output itself doesn't go to the console unless explicitly desired by the command itself
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        log_error "Command failed: $*"
        # Optionally, re-throw error if needed, but set -e should handle it.
        return 1 # Indicate failure
    fi
}

log_sudo_cmd() {
    log "SUDO CMD: $*"
    if ! sudo "$@" >> "$LOG_FILE" 2>&1; then
        log_error "Sudo command failed: $*"
        return 1
    fi
}

# === Dependency Checking ===
check_dependencies() {
    log "Checking required dependencies..."
    
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        log_error "Template directory not found: $TEMPLATE_DIR"
        exit 1
    fi
    
    local deps=("mkpasswd" "sfdisk" "nixos-generate-config" "nixos-install" "lsblk" "findmnt" "mktemp" "blkid" "udevadm" "tee" "awk" "sed" "grep" "tr" "sync" "partprobe" "blockdev" "mountpoint" "swapon" "swapoff" "mkfs.vfat" "mkswap")
    # Add mkfs for the default root fs type
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
        prompt_display="[y/N]" # Default to No on error
        default_response_char="N"
    fi

    while true; do
        # Prompt on stderr to ensure it's visible even if stdout is captured by log
        read -r -p "${question} ${prompt_display}: " response >&2
        local response_lower
        response_lower=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response_lower" in
            y|yes)
                return 0
                ;;
            n|no)
                echo "You selected 'No'. The question will be asked again unless this is a final confirmation. Press Ctrl+C to abort script." >&2
                # For critical confirmations, 'no' should mean abort or re-ask.
                # This function currently always re-asks on 'no'.
                ;;
            "") # Empty input means default
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0
                else # Default is No
                    echo "Default is 'No'. The question will be asked again unless this is a final confirmation. Press Ctrl+C to abort script." >&2
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
    # Escape characters that are special to sed's s/// command
    printf '%s' "$1" | sed -e 's/[\/&]/\\&/g' -e 's/[\[.*^$(){}+?|\\]/\\&/g'
}

# === Progress Indicator ===
show_progress() {
    local pid=$1
    local msg="$2"
    
    log "Starting background process '$msg' with PID $pid"
    while kill -0 "$pid" 2>/dev/null; do # Check if PID exists
        for i in / - \\ \|; do
            printf '\r%s %s' "$msg" "$i" >&2 # Print to stderr
            sleep 0.25
        done
    done
    # Check how the process exited, if possible (might need to wait for it properly)
    # This simple spinner doesn't capture exit status, nixos-install wait does.
    printf '\r%s... Done!                     \n' "$msg" >&2 # Print to stderr, clear line
    log "Background process '$msg' with PID $pid presumed completed."
}


# === Cleanup Function ===
cleanup_on_error() {
    log_error "An error occurred at line $LINENO. Performing cleanup..."
    
    # Unmount in reverse order
    if mountpoint -q /mnt/boot 2>/dev/null; then
        log "Attempting to unmount /mnt/boot"
        sudo umount /mnt/boot || log_error "Failed to unmount /mnt/boot during cleanup."
    fi
    
    if mountpoint -q /mnt 2>/dev/null; then
        log "Attempting to unmount /mnt"
        sudo umount /mnt || log_error "Failed to unmount /mnt during cleanup."
    fi
    
    # Turn off swap
    if [[ -n "$SWAP_DEVICE_NODE" && -e "$SWAP_DEVICE_NODE" ]]; then # Check if var is set and node exists
        log "Attempting to swapoff $SWAP_DEVICE_NODE"
        sudo swapoff "$SWAP_DEVICE_NODE" 2>/dev/null || true # Ignore error if already off or fails
    fi
    
    log "Attempting to swapoff all devices"
    sudo swapoff -a 2>/dev/null || true # Ignore error
    
    log "Cleanup attempt completed."
    echo "An error occurred. Check the log file for details: $LOG_FILE" >&2
    # exit 1 # The trap ERR should cause script to exit after this.
}

# Set trap for cleanup on ERR (any command fails), INT (Ctrl+C), TERM (kill)
trap cleanup_on_error ERR INT TERM

# === Disk Management Functions ===
show_available_disks() {
    echo "Available block devices (disks only):" >&2
    # lsblk: -d for no slaves, -p for full paths, -n for no header, -o select columns
    # grep for 'disk' type
    lsblk -dpno NAME,SIZE,MODEL,TYPE | grep -E "disk$" | while IFS= read -r line; do
        local disk_path
        disk_path=$(echo "$line" | awk '{print $1}')
        # Ensure it's a block device (redundant with lsblk but safe)
        if [[ -b "$disk_path" ]]; then
            echo "  $line" >&2
        fi
    done
}

prepare_mount_points() {
    log "Checking and preparing mount points (/mnt, /mnt/boot)..."
    local mount_points=("/mnt/boot" "/mnt") # Unmount /mnt/boot before /mnt
    
    for mp in "${mount_points[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            local current_device
            current_device=$(findmnt -n -o SOURCE --target "$mp")
            log "Mount point '$mp' is currently mounted by device '$current_device'"
            
            # Check if it's a partition of the target disk we are about to format
            # This check is a bit heuristic. A more robust check might involve checking parent device.
            if [[ "$current_device" == "$TARGET_DISK"* ]]; then
                 log "Device '$current_device' appears to be part of the target disk '$TARGET_DISK'."
                 log "Unmounting '$current_device' from '$mp'..."
                 sudo umount -f "$mp" || { log_error "Failed to unmount '$mp'. Exiting."; exit 1; }
            else
                # It's some other device mounted. Ask user.
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
    
    if ! [[ "$total_bytes" =~ ^[0-9]+$ ]] || [ "$total_bytes" -le 0 ]; then # Must be positive number
        log_error "Could not determine a valid disk size for $TARGET_DISK (got '$total_bytes' bytes). Exiting."
        exit 1
    fi
    
    local total_mib=$((total_bytes / 1024 / 1024))
    log "Total disk size: $total_mib MiB."

    local efi_start_mib=1 # Start at 1MiB for alignment and to leave space for GPT headers
    local efi_size_mib=$DEFAULT_EFI_SIZE_MiB
    local swap_size_req_mib=$((SWAP_SIZE_GB * 1024))
    local min_root_size_mib=20480 # Minimum 20GiB for root, adjust as needed

    # Check if disk is too small for even minimal setup
    if [ $((efi_start_mib + efi_size_mib + swap_size_req_mib + min_root_size_mib)) -gt "$total_mib" ]; then
        log "Disk is potentially too small ($total_mib MiB) for requested EFI ($efi_size_mib MiB), Swap ($swap_size_req_mib MiB), and minimum Root ($min_root_size_mib MiB)."
        # Try reducing EFI if it's the default and larger than a smaller sensible default (e.g., 256MiB)
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
    # Calculate root_end ensuring swap has space. The last partition (swap) takes remaining space up to requested.
    local swap_start_candidate=$((total_mib - swap_size_req_mib))

    if [ "$swap_start_candidate" -le "$root_start_mib" ]; then
        log_error "Not enough space for root partition after allocating EFI, or Swap is too large. Root starts at $root_start_mib, Swap would start at $swap_start_candidate (calculated from end). Exiting."
        exit 1
    fi
    
    # Swap partition will be at the end.
    local swap_size_actual_mib=$swap_size_req_mib
    # If remaining space is less than requested swap, use all remaining for swap (but ensure it's reasonable)
    if [ $((total_mib - root_start_mib)) -lt "$swap_size_req_mib" ]; {
        log "Warning: Requested swap size ($swap_size_req_mib MiB) is larger than available after EFI. Reducing swap size."
        swap_size_actual_mib=$((total_mib - root_start_mib - 1)) # -1 for safety margin
        if [ "$swap_size_actual_mib" -lt 512 ]; then # Min sensible swap
            log_error "Calculated swap size ($swap_size_actual_mib MiB) is too small. Check disk space or SWAP_SIZE_GB. Exiting."
            exit 1
        fi
    }
    
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
    
    # Export calculated values (ensure they are global or pass them)
    # These are used by create_partitions, so ensure they are correctly scoped or returned.
    # For bash, they are global once set here if not declared local.
    EFI_START_MIB_CALC=$efi_start_mib
    EFI_SIZE_MIB_CALC=$efi_size_mib
    ROOT_START_MIB_CALC=$root_start_mib
    ROOT_SIZE_MIB_CALC=$root_size_mib
    SWAP_START_MIB_CALC=$swap_start_mib
    SWAP_SIZE_MIB_CALC=$swap_size_actual_mib
}


create_partitions() {
    log "Creating partition scheme on $TARGET_DISK..."
    
    local part_prefix="" # Will be 'p' for NVMe/loop, empty for sdX
    if [[ "$TARGET_DISK" == /dev/nvme* || "$TARGET_DISK" == /dev/loop* ]]; then
        part_prefix="p" 
    fi
    EFI_DEVICE_NODE="${TARGET_DISK}${part_prefix}1"
    ROOT_DEVICE_NODE="${TARGET_DISK}${part_prefix}2"
    SWAP_DEVICE_NODE="${TARGET_DISK}${part_prefix}3"
    
    # GPT type GUIDs
    local efi_type_guid="C12A7328-F81F-11D2-BA4B-00A0C93EC93B" # EFI System Partition
    local root_type_guid="0FC63DAF-8483-4772-8E79-3D69D8477DE4" # Linux x86-64 root (/) for systemd auto-discovery
    local swap_type_guid="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F" # Linux swap
    
    # sfdisk input. Using MiB explicitly.
    # Format: [device] : start=N, size=N, type=GUID, name="NAME"
    # Note: sfdisk uses sectors by default, but `unit: MiB` changes that.
    # The device names in the input are informational for sfdisk v2.26+; partitioning is by order.
    # We use the calculated global variables (e.g., EFI_START_MIB_CALC)
    local sfdisk_input # Using a variable makes it easier to log
    sfdisk_input=$(cat <<EOF
label: gpt
unit: MiB
${EFI_DEVICE_NODE} : start=${EFI_START_MIB_CALC}, size=${EFI_SIZE_MIB_CALC}, type=${efi_type_guid}, name="${EFI_PART_NAME}"
${ROOT_DEVICE_NODE} : start=${ROOT_START_MIB_CALC}, size=${ROOT_SIZE_MIB_CALC}, type=${root_type_guid}, name="${ROOT_PART_NAME}"
${SWAP_DEVICE_NODE} : start=${SWAP_START_MIB_CALC}, size=${SWAP_SIZE_MIB_CALC}, type=${swap_type_guid}, name="${SWAP_PART_NAME}"
EOF
) # End heredoc
    
    log "Applying partition scheme with sfdisk. Details:"
    echo -e "$sfdisk_input" | sudo tee -a "$LOG_FILE" # Log the input being fed to sfdisk
    
    # Use printf to avoid issues with echo's interpretation of backslashes if any were in sfdisk_input
    printf "%s" "$sfdisk_input" | sudo sfdisk \
        --wipe always \
        --wipe-partitions always \
        "$TARGET_DISK"

    log "Partitioning supposedly complete. Informing kernel of changes..."
    sync # Ensure all writes are flushed
    sudo partprobe "$TARGET_DISK" || log "partprobe $TARGET_DISK failed, attempting blockdev --rereadpt..."
    sudo blockdev --rereadpt "$TARGET_DISK" || log "blockdev --rereadpt $TARGET_DISK also failed. Udev might still pick it up."
    
    log "Waiting for udev to settle partition changes..."
    sudo udevadm settle
    sleep 3 # Brief pause for devices to become fully available
    
    log "Partition scheme applied. Verifying partitions on $TARGET_DISK:"
    sudo sfdisk -l "$TARGET_DISK" | sudo tee -a "$LOG_FILE" # Log the resulting partition table
}


format_partitions() {
    log "Formatting partitions..."
    
    local max_wait_seconds=20 # Increased wait time for device nodes
    local current_wait=0
    log "Waiting up to $max_wait_seconds seconds for device nodes: $EFI_DEVICE_NODE, $ROOT_DEVICE_NODE, $SWAP_DEVICE_NODE"
    
    while [[ (! -b "$EFI_DEVICE_NODE" || ! -b "$ROOT_DEVICE_NODE" || ! -b "$SWAP_DEVICE_NODE") && "$current_wait" -lt "$max_wait_seconds" ]]; do
        log "Device nodes not all available yet (waited $current_wait s). Triggering udev and waiting..."
        sudo udevadm trigger # Ask udev to re-evaluate devices
        sudo udevadm settle   # Wait for udev processing to complete
        sleep 1
        current_wait=$((current_wait + 1))
    done
    
    if [[ ! -b "$EFI_DEVICE_NODE" ]]; then log_error "$EFI_DEVICE_NODE is not a block device!"; fi
    if [[ ! -b "$ROOT_DEVICE_NODE" ]]; then log_error "$ROOT_DEVICE_NODE is not a block device!"; fi
    if [[ ! -b "$SWAP_DEVICE_NODE" ]]; then log_error "$SWAP_DEVICE_NODE is not a block device!"; fi

    if [[ ! -b "$EFI_DEVICE_NODE" || ! -b "$ROOT_DEVICE_NODE" || ! -b "$SWAP_DEVICE_NODE" ]]; then
        log_error "One or more partition device nodes did not become available after $max_wait_seconds seconds. Exiting."
        lsblk "$TARGET_DISK" -o NAME,PATH,TYPE,SIZE | sudo tee -a "$LOG_FILE" # Log current state
        exit 1
    fi
    log "All partition device nodes are available."
    
    log "Formatting EFI partition ($EFI_DEVICE_NODE) as FAT32..."
    log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"
    
    log "Formatting Root partition ($ROOT_DEVICE_NODE) as $DEFAULT_ROOT_FS_TYPE..."
    log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE" # -F to force if already formatted
    
    log "Formatting Swap partition ($SWAP_DEVICE_NODE)..."
    log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE" # -f to force
    
    log "Partitions formatted. Verifying UUIDs and Labels post-formatting:"
    sudo blkid "$EFI_DEVICE_NODE" | sudo tee -a "$LOG_FILE"
    sudo blkid "$ROOT_DEVICE_NODE" | sudo tee -a "$LOG_FILE"
    sudo blkid "$SWAP_DEVICE_NODE" | sudo tee -a "$LOG_FILE"
    
    log "Partition formatting completed successfully."
}


mount_filesystems() {
    log "Mounting filesystems..."
    
    log "Mounting Root partition $ROOT_DEVICE_NODE on /mnt"
    sudo mount "$ROOT_DEVICE_NODE" /mnt
    if ! mountpoint -q /mnt; then # Verify mount
        log_error "Failed to mount root filesystem $ROOT_DEVICE_NODE on /mnt. Exiting."
        exit 1
    fi
    
    log "Creating EFI mount point /mnt/boot"
    sudo mkdir -p /mnt/boot
    log "Mounting EFI partition $EFI_DEVICE_NODE on /mnt/boot"
    sudo mount "$EFI_DEVICE_NODE" /mnt/boot
    if ! mountpoint -q /mnt/boot; then # Verify mount
        log_error "Failed to mount EFI filesystem $EFI_DEVICE_NODE on /mnt/boot. Exiting."
        # Attempt to unmount root before exiting if boot mount failed
        sudo umount /mnt 2>/dev/null || true
        exit 1
    fi
    
    log "Enabling swap on $SWAP_DEVICE_NODE"
    sudo swapon "$SWAP_DEVICE_NODE"
    # No standard easy way to verify swapon other than checking swapon -s or free, or exit code
    
    log "Filesystems mounted and swap enabled successfully."
    log "Current filesystem layout on $TARGET_DISK:"
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,PARTUUID "$TARGET_DISK" | sudo tee -a "$LOG_FILE"
}

# === Configuration Generation Functions ===
generate_flake_with_modules() {
    local template_file="$1"    # e.g., "flake.nix.template"
    local output_file="$2"      # e.g., "flake.nix"
    local module_imports_str="$3" # Multiline string of import statements
    local template_path="${TEMPLATE_DIR}/${template_file}"
    local output_path="${TARGET_NIXOS_CONFIG_DIR}/${output_file}"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template file for $output_file not found: $template_path. Exiting."
        return 1 # Use return for functions, exit for script
    fi
    
    log "Generating $output_file from template $template_path..."
    
    local temp_processed_vars temp_final_output
    temp_processed_vars=$(mktemp)
    temp_final_output=$(mktemp)
    # Ensure temp files are cleaned up if function errors out or script exits
    # trap "rm -f '$temp_processed_vars' '$temp_final_output'" RETURN # Cleans up when function returns

    # First pass: substitute variables (e.g., __HOSTNAME__)
    # Using a simpler sed invocation for clarity if escape_for_sed is robust
    sed \
        -e "s/__NIXOS_USERNAME__/$(escape_for_sed "$NIXOS_USERNAME")/g" \
        -e "s/__PASSWORD_HASH__/$(escape_for_sed "$PASSWORD_HASH")/g" \
        -e "s/__GIT_USERNAME__/$(escape_for_sed "$GIT_USERNAME")/g" \
        -e "s/__GIT_USEREMAIL__/$(escape_for_sed "$GIT_USEREMAIL")/g" \
        -e "s/__HOSTNAME__/$(escape_for_sed "$HOSTNAME")/g" \
        -e "s/__TARGET_DISK_FOR_GRUB__/$(escape_for_sed "$TARGET_DISK")/g" \
        "$template_path" > "$temp_processed_vars"

    # Second pass: inject module imports string
    local placeholder="#__NIXOS_MODULE_IMPORTS_PLACEHOLDER__#"
    if grep -qF "$placeholder" "$temp_processed_vars"; then
        # Using awk for safer multiline replacement.
        # The 'imports' variable in awk needs to be properly escaped if it contains backslashes or quotes itself.
        # However, module_imports_str should be simple relative paths.
        awk -v imports="$module_imports_str" -v placeholder="$placeholder" '
            {
                if (index($0, placeholder)) {
                    # Substitute the placeholder line with the content of 'imports'
                    print imports
                } else {
                    print $0
                }
            }
        ' "$temp_processed_vars" > "$temp_final_output"
        log "Module imports injected into $output_file template."
    else
        cp "$temp_processed_vars" "$temp_final_output" # No placeholder, use as is
        log "No module import placeholder '$placeholder' found in $template_file. Using variable-substituted content directly."
    fi
    
    log "Installing generated file to $output_path"
    if sudo mv "$temp_final_output" "$output_path"; then
        sudo chmod 644 "$output_path"
        log "$output_file generated and installed successfully at $output_path."
        rm -f "$temp_processed_vars" # Clean up the first temp file
        # temp_final_output was moved, so no need to rm it.
        return 0
    else
        log_error "Failed to install $output_file to $output_path. Temp files: $temp_processed_vars, $temp_final_output. Exiting."
        # Keep temp files for debugging if mv fails
        return 1
    fi
}


copy_nix_modules() {
    log "Copying custom NixOS module files from $TEMPLATE_DIR to $TARGET_NIXOS_CONFIG_DIR..."
    
    local files_to_copy
    # Find .nix files, excluding flake.nix.template and hardware-configuration.nix
    # as they are specially handled.
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
        if sudo cp "$nix_file_path" "$dest_path"; then
            sudo chmod 644 "$dest_path"
        else
            log_error "Failed to copy $filename to $dest_path. Exiting."
            exit 1 # Critical failure
        fi
    done
    log "Custom NixOS module files copied."
}


generate_module_imports() {
    # This function's output is captured by command substitution.
    # Do not use 'log' functions here directly if they output to stdout.
    # echo to stdout is expected.
    local imports_array=()
    
    # Find .nix files in TEMPLATE_DIR that were copied (or would be copied)
    # These paths must be relative to flake.nix (e.g., ./module.nix)
    local copied_module_files
    copied_module_files=$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*.nix" -type f \
                            -not -name "flake.nix.template" \
                            -not -name "hardware-configuration.nix")
                            # Add other exclusions if needed, e.g. -not -name "home-manager-user.nix"

    if [ -n "$copied_module_files" ]; then
        echo "$copied_module_files" | while IFS= read -r module_path; do
            local filename
            filename=$(basename "$module_path")
            # Add specific exclusions if a file exists in TEMPLATE_DIR but shouldn't be in system imports
            # if [[ "$filename" == "some-special-template.nix" ]]; then continue; fi
            imports_array+=("      ./${filename}") # Standard indentation for flake.nix imports
        done
    fi
    
    # Always add hardware-configuration.nix, which is generated in TARGET_NIXOS_CONFIG_DIR
    imports_array+=("      ./hardware-configuration.nix")

    local import_string=""
    if [[ ${#imports_array[@]} -gt 0 ]]; then
        printf -v import_string '%s\n' "${imports_array[@]}"
        import_string=${import_string%?} # Remove the last newline
    fi
    
    echo "$import_string" # Output the final string of import lines
}


# === User Input Functions ===
get_user_input() {
    log "Gathering user configuration..."
    
    show_available_disks # Output to stderr
    echo "" >&2 # Extra newline for readability
    
    while true; do
        read -r -p "Enter target disk (e.g., /dev/sda, /dev/nvme0n1): " TARGET_DISK >&2
        if [[ -b "$TARGET_DISK" ]]; then
            if confirm "You selected '$TARGET_DISK'. ALL DATA ON THIS DISK WILL BE ERASED! This is irreversible. Are you absolutely sure?" "N"; then
                break # User confirmed
            else
                log "User declined disk selection $TARGET_DISK. Asking again."
                # Loop continues
            fi
        else
            echo "Error: '$TARGET_DISK' is not a valid block device or does not exist. Please check the path." >&2
        fi
    done
    log "User confirmed target disk for installation: $TARGET_DISK"
    
    while [[ -z "$NIXOS_USERNAME" ]]; do
        read -r -p "Enter username for the primary NixOS user: " NIXOS_USERNAME >&2
        # Basic validation for typical Linux usernames
        if ! [[ "$NIXOS_USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ && ${#NIXOS_USERNAME} -le 32 ]]; then
            echo "Invalid username. Use lowercase letters, numbers, underscores, hyphens. Start with letter/underscore. Max 32 chars." >&2
            NIXOS_USERNAME="" # Clear to re-ask
        fi
    done
    log "NixOS username set to: $NIXOS_USERNAME"
    
    while true; do
        read -r -s -p "Enter password for user '$NIXOS_USERNAME': " pass1 >&2
        echo "" >&2 # Newline after password input
        read -r -s -p "Confirm password: " pass2 >&2
        echo "" >&2 # Newline
        
        if [[ -z "$pass1" ]]; then
            echo "Password cannot be empty. Please try again." >&2
            continue
        fi

        if [[ "$pass1" == "$pass2" ]]; then
            # Generate SHA512 crypt hash. mkpasswd from shadow utils is expected.
            # Piping password to stdin of mkpasswd is safer than command-line arg.
            # `-m sha-512` specifies method. `-s` without arg or with `-` reads salt from stdin or generates if stdin also provides password.
            # A common pattern that works with shadow's mkpasswd:
            # Read password from stdin, generate random salt.
            PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 --stdin) 
            # Alternative using python if mkpasswd is problematic or for specific salt control:
            # PASSWORD_HASH=$(NEWPASSWD="$pass1" python3 -c 'import crypt, os; print(crypt.crypt(os.environ["NEWPASSWD"], crypt.mksalt(crypt.METHOD_SHA512)))')

            if [[ -n "$PASSWORD_HASH" && "$PASSWORD_HASH" == \$6\$* ]]; then # Check if it looks like a SHA512 hash
                log "Password hash generated successfully for user $NIXOS_USERNAME."
                break # Password set
            else
                log_error "Failed to generate a valid password hash. mkpasswd output: '$PASSWORD_HASH'"
                echo "Password hash generation failed. Please try again. Ensure 'mkpasswd' (from shadow utils) is working." >&2
                # Do not exit, allow user to retry or debug mkpasswd if necessary.
            fi
        else
            echo "Passwords do not match. Please try again." >&2
        fi
    done
    unset pass1 pass2 # Clear password variables from memory
    
    while [[ -z "$GIT_USERNAME" ]]; do
        read -r -p "Enter your Git username (for user's .gitconfig, e.g., 'Your Name'): " GIT_USERNAME >&2
    done
    log "Git username set to: $GIT_USERNAME"
    
    while [[ -z "$GIT_USEREMAIL" ]]; do
        read -r -p "Enter your Git email (for user's .gitconfig): " GIT_USEREMAIL >&2
         if ! [[ "$GIT_USEREMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then # Basic email format check
            echo "Invalid email address format. Please try again." >&2
            GIT_USEREMAIL="" # Clear to re-ask
        fi
    done
    log "Git email set to: $GIT_USEREMAIL"
    
    read -r -p "Enter hostname for the system (e.g., 'nixos-desktop', default: nixos): " HOSTNAME >&2
    HOSTNAME=${HOSTNAME:-nixos} # Default to 'nixos' if empty
    # Basic hostname validation (RFC 952/1123 subset)
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
    
    prepare_mount_points # Unmount /mnt and /mnt/boot if necessary
    calculate_partitions # Calculate sizes based on disk and globals
    
    log "Turning off any existing swap devices on the system..."
    sudo swapoff -a 2>/dev/null || log "No active swap to turn off, or already off."
    
    create_partitions # Create partition table using calculated sizes
    format_partitions # Format the newly created partitions
    mount_filesystems # Mount them to /mnt and /mnt/boot, enable swap
    
    log "Disk operations (partitioning, formatting, mounting) completed successfully."
}


generate_nixos_config() {
    log "Generating NixOS configuration files in $TARGET_NIXOS_CONFIG_DIR..."
    
    log "Running 'nixos-generate-config --root /mnt' to create hardware-configuration.nix..."
    # The command itself will output to log via log_sudo_cmd
    if ! sudo nixos-generate-config --root /mnt >> "$LOG_FILE" 2>&1; then
        log_error "'nixos-generate-config --root /mnt' failed. Check logs. Exiting."
        exit 1
    fi
    log "'nixos-generate-config' completed."

    local hw_conf_path="${TARGET_NIXOS_CONFIG_DIR}/hardware-configuration.nix"
    if sudo test -f "$hw_conf_path"; then
        log "Verifying generated $hw_conf_path content (key entries):"
        # Log specific, important lines from hardware-configuration.nix
        # Use process substitution to tee the output of grep to the log file as well as potentially to console via log function
        # However, simple grep and redirect to log is fine here.
        {
            echo "--- Relevant entries from $hw_conf_path ---"
            sudo grep -E 'fileSystems\."/"|fileSystems\."/boot"|boot\.loader\.(grub|systemd-boot)\.(device|enable|efiSupport|canTouchEfiVariables)|networking\.hostName|imports' "$hw_conf_path" || echo "No matching entries found by grep in $hw_conf_path (this might be okay if using flakes heavily)."
            echo "--- End of $hw_conf_path excerpt ---"
        } | sudo tee -a "$LOG_FILE" >/dev/null # Tee to log, suppress from console here
    else
        log_error "$hw_conf_path NOT FOUND after nixos-generate-config execution! This is critical. Exiting."
        exit 1
    fi
    
    # Remove default configuration.nix if it exists (we are using a flake-based setup)
    if sudo test -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"; then
        log "Removing default ${TARGET_NIXOS_CONFIG_DIR}/configuration.nix (will be replaced by flake structure)."
        sudo rm -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"
    fi
    
    # Ensure target directory for configs exists (should be created by nixos-generate-config)
    sudo mkdir -p "$TARGET_NIXOS_CONFIG_DIR" # Should already exist but -p makes it safe
    
    copy_nix_modules # Copy user's custom .nix files from TEMPLATE_DIR
    
    log "Generating the string of module import statements for flake.nix..."
    local module_imports_str
    module_imports_str=$(generate_module_imports) # This now correctly includes ./hardware-configuration.nix
    log "Module import statements for flake.nix will be:\n$module_imports_str"
    
    log "Generating main flake.nix from template..."
    if ! generate_flake_with_modules "flake.nix.template" "flake.nix" "$module_imports_str"; then
        log_error "Failed to generate flake.nix. Exiting."
        exit 1
    fi
    
    log "NixOS configuration generation process completed."
    log "IMPORTANT NOTE FOR THE USER:"
    log "  Please ensure your flake.nix and any custom NixOS modules (now in $TARGET_NIXOS_CONFIG_DIR)"
    log "  correctly utilize the settings from 'hardware-configuration.nix', especially for filesystems and bootloader."
    log "  For EFI systems, confirm your NixOS configuration enables an EFI-compatible bootloader"
    log "  (e.g., systemd-boot or GRUB for EFI) and can update EFI variables if needed."
    log "  Example for systemd-boot: boot.loader.systemd-boot.enable = true; boot.loader.efi.canTouchEfiVariables = true;"
    log "  Example for GRUB EFI: boot.loader.grub.enable = true; boot.loader.grub.efiSupport = true; boot.loader.efi.canTouchEfiVariables = true; boot.loader.grub.device = \"nodev\";"
}


install_nixos() {
    log "Starting NixOS installation phase..."
    echo "" >&2
    echo "The NixOS installation process will now begin." >&2
    echo "This may take a significant amount of time, depending on your internet connection and system speed." >&2
    echo "Please be patient. You can monitor progress details in the log file: $LOG_FILE" >&2
    echo "(e.g., run 'sudo tail -f $LOG_FILE' in another terminal)" >&2
    echo "" >&2
    
    # Confirmation before starting the actual nixos-install command
    if confirm "Proceed with NixOS installation using the generated configuration at '${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}'?" "Y"; then
        log "User confirmed. Running 'nixos-install --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}'"
        
        # Run nixos-install in the background to allow the progress spinner
        # All output (stdout and stderr) from nixos-install goes to the main log file.
        sudo nixos-install --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}" &>> "$LOG_FILE" &
        local install_pid=$!
        
        show_progress $install_pid "Installing NixOS (PID: $install_pid)" # This shows spinner on stderr
        
        local install_status=0 # Assume success initially
        if ! wait "$install_pid"; then
            install_status=$? # Get actual exit status if wait fails
            log_error "NixOS installation command (PID: $install_pid) failed with exit status: $install_status"
        else
            log "NixOS installation command (PID: $install_pid) completed successfully (exit status: $install_status)."
        fi

        # Check status after wait
        if [ "$install_status" -eq 0 ]; then
            log "NixOS installation has completed successfully!"
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
                action=${action:-1} # Default to 1 (Reboot)

                case "$action" in
                    1)
                        log "User chose to reboot."
                        echo "Rebooting the system into NixOS..." >&2
                        sudo reboot
                        # Script should terminate here due to reboot
                        exit 0 
                        ;;
                    2)
                        log "User chose to power off."
                        echo "Powering off the system..." >&2
                        sudo poweroff
                        # Script should terminate here due to poweroff
                        exit 0 
                        ;;
                    *)
                        echo "Invalid selection. Please enter 1 for Reboot or 2 for Power off." >&2
                        ;;
                esac
            done
        else # nixos-install failed
            log_error "NixOS installation FAILED. Exit status from nixos-install was: $install_status"
            echo "" >&2
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "!!! NixOS Installation FAILED. Please check the log file:          !!!" >&2
            echo "!!!   $LOG_FILE                                                    !!!"
            echo "!!! You may also find more specific errors from nixos-install in:  !!!"
            echo "!!!   /mnt/var/log/nixos-install.log (if it was created)           !!!"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "" >&2
            echo "Common reasons for failure include:" >&2
            echo "  - Network connectivity issues during package downloads." >&2
            echo "  - Errors in your custom NixOS configuration/flake (syntax, missing options)." >&2
            echo "  - Insufficient disk space (though this script attempts checks)." >&2
            echo "  - Hardware compatibility issues not addressed in configuration." >&2
            # cleanup_on_error should have run via trap ERR
            exit 1 # Explicitly exit with error status
        fi
    else
      log "NixOS installation process aborted by user before starting 'nixos-install'."
      echo "NixOS Installation aborted by user." >&2
      # No error, user chose not to proceed
    fi
}


# === Main Script Execution ===
main() {
    # Attempt to acquire sudo privileges upfront if script is not run as root
    # This helps avoid later sudo prompts interrupting the flow, if sudoers is configured for it.
    if [[ $EUID -ne 0 ]]; then # Check if not already root
        if ! sudo -n true 2>/dev/null; then # Check if passwordless sudo is available
            echo "This script requires sudo privileges. Attempting to acquire..." >&2
            if ! sudo true; then # Prompt for password if needed
                echo "Failed to acquire sudo privileges. Please run with sudo or ensure passwordless sudo is configured. Exiting." >&2
                exit 1
            fi
            echo "Sudo privileges acquired." >&2
        else
            echo "Passwordless sudo available or already has privileges." >&2
        fi
    fi

    # Initialize log file (create if not exists, ensure writable by current process via sudo tee)
    echo "Initializing NixOS Installation Script. Log file: $LOG_FILE" | sudo tee "$LOG_FILE" >/dev/null 
    # First message to log, also creates/truncates log with sudo if needed. Use tee -a for append later.

    # --- Script Header / Warning ---
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
        exit 0 # Clean exit, user chose not to proceed
    fi
    
    log "User accepted responsibility. Starting NixOS installation process..."
    log "Script execution started at: $(date)"
    log "Script directory: $SCRIPT_DIR"
    log "Template directory: $TEMPLATE_DIR"
    
    check_dependencies        # Verify all required tools are present
    get_user_input            # Gather disk, user, hostname info
    partition_and_format_disk # Partition, format, and mount target disk
    generate_nixos_config     # Create hardware-config, flake.nix, copy modules
    install_nixos             # Run nixos-install and handle post-install actions

    log "Main script execution sequence finished successfully."
    # The script will exit via reboot/poweroff inside install_nixos if successful.
    # If install_nixos was aborted before reboot/poweroff, this log line might be reached.
}

# --- Run Main Function ---
# All output from main and its sub-functions should be handled by logging functions
# or explicitly sent to >&2 for user interaction.
main "$@"

exit 0 # Explicit success exit if script reaches here (e.g., user chose not to reboot/poweroff immediately)
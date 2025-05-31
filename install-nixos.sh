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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | tee -a "$LOG_FILE" >&2
}

log_cmd() {
    log "CMD: $*"
    "$@"
}

log_sudo_cmd() {
    log "SUDO CMD: $*"
    sudo "$@"
}

# === Dependency Checking ===
check_dependencies() {
    log "Checking required dependencies..."
    local deps=("mkpasswd" "sfdisk" "nixos-generate-config" "nixos-install" "lsblk" "findmnt" "mktemp")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies and try again."
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
        read -r -p "${question} ${prompt_display}: " response
        local response_lower
        response_lower=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response_lower" in
            y|yes)
                return 0
                ;;
            n|no)
                echo "You selected 'No'. The question will be asked again. Press Ctrl+C to abort."
                ;;
            "")
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0
                else
                    echo "Default is 'No'. The question will be asked again. Press Ctrl+C to abort."
                fi
                ;;
            *)
                echo "Invalid input. Please type 'y', 'n', or press Enter for default."
                ;;
        esac
    done
}

# === String Escaping Functions ===
escape_for_sed() {
    printf '%s' "$1" | sed 's/[[\.*^$()+?{|]/\\&/g'
}

# === Progress Indicator ===
show_progress() {
    local pid=$1
    local msg="$2"
    
    while kill -0 $pid 2>/dev/null; do
        for i in / - \\ \|; do
            printf '\r%s %s' "$msg" "$i"
            sleep 0.25
        done
    done
    printf '\r%s... Done!\n' "$msg"
}

# === Cleanup Function ===
cleanup_on_error() {
    log "Performing cleanup due to error..."
    
    # Unmount in reverse order
    if mountpoint -q /mnt/boot 2>/dev/null; then
        sudo umount /mnt/boot || log_error "Failed to unmount /mnt/boot"
    fi
    
    if mountpoint -q /mnt 2>/dev/null; then
        sudo umount /mnt || log_error "Failed to unmount /mnt"
    fi
    
    # Turn off swap
    if [[ -n "$SWAP_DEVICE_NODE" && -e "$SWAP_DEVICE_NODE" ]]; then
        sudo swapoff "$SWAP_DEVICE_NODE" 2>/dev/null || true
    fi
    
    sudo swapoff -a 2>/dev/null || true
    
    log "Cleanup completed."
}

# Set trap for cleanup
trap cleanup_on_error ERR

# === Disk Management Functions ===
show_available_disks() {
    echo "Available block devices:"
    lsblk -dpno NAME,SIZE,MODEL,TYPE | grep -E "disk" | while IFS= read -r line; do
        disk=$(echo "$line" | awk '{print $1}')
        if [[ -b "$disk" ]]; then
            echo "  $line"
        fi
    done
}

prepare_mount_points() {
    log "Checking and preparing mount points..."
    local mount_points=("/mnt/boot" "/mnt")
    
    for mp in "${mount_points[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            local current_device
            current_device=$(findmnt -n -o SOURCE --target "$mp")
            log "Mount point '$mp' is currently mounted by '$current_device'"
            
            if [[ "$current_device" == "$TARGET_DISK"* ]]; then
                log "Unmounting target disk partition from '$mp'..."
                sudo umount -f "$mp" || log_error "Failed to unmount '$mp'"
            else
                if confirm "Mount point '$mp' is in use by '$current_device'. Unmount it?" "N"; then
                    sudo umount -f "$mp" || {
                        log_error "Failed to unmount '$mp'. Please unmount manually."
                        exit 1
                    }
                else
                    log_error "Cannot proceed with '$mp' in use."
                    exit 1
                fi
            fi
        fi
    done
}

calculate_partitions() {
    local total_bytes
    total_bytes=$(sudo blockdev --getsize64 "$TARGET_DISK")
    
    if ! [[ "$total_bytes" =~ ^[0-9]+$ ]] || [ "$total_bytes" -eq 0 ]; then
        log_error "Could not determine disk size for $TARGET_DISK"
        exit 1
    fi
    
    local total_mib=$((total_bytes / 1024 / 1024))
    local efi_start=1
    local efi_size=$DEFAULT_EFI_SIZE_MiB
    local swap_size_mib=$((SWAP_SIZE_GB * 1024))
    local root_start=$((efi_start + efi_size))
    local root_end=$((total_mib - swap_size_mib))
    local root_size=$((root_end - root_start))
    local swap_start=$root_end
    
    if [ "$root_size" -le 1024 ]; then
        log_error "Insufficient space for root partition (${root_size}MiB)"
        exit 1
    fi
    
    log "Partition layout: EFI=${efi_size}MiB, Root=${root_size}MiB, Swap=${swap_size_mib}MiB"
    
    # Export calculated values
    EFI_START=$efi_start
    EFI_SIZE=$efi_size
    ROOT_START=$root_start
    ROOT_SIZE=$root_size
    SWAP_START=$swap_start
    SWAP_SIZE_MIB=$swap_size_mib
}

create_partitions() {
    log "Creating partition scheme on $TARGET_DISK..."
    
    # Determine partition suffix
    local part_suffix="1"
    if [[ "$TARGET_DISK" == /dev/nvme* || "$TARGET_DISK" == /dev/loop* ]]; then
        part_suffix="p1"
        EFI_DEVICE_NODE="${TARGET_DISK}p1"
        ROOT_DEVICE_NODE="${TARGET_DISK}p2"
        SWAP_DEVICE_NODE="${TARGET_DISK}p3"
    else
        EFI_DEVICE_NODE="${TARGET_DISK}1"
        ROOT_DEVICE_NODE="${TARGET_DISK}2"
        SWAP_DEVICE_NODE="${TARGET_DISK}3"
    fi
    
    # GPT type GUIDs
    local efi_type="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
    local root_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
    local swap_type="0657FD6D-A4AB-43C4-84E5-0933C84B4F4F"
    
    # Create sfdisk input
    local sfdisk_input="label: gpt
name=\"${EFI_PART_NAME}\", start=${EFI_START}M, size=${EFI_SIZE}M, type=${efi_type}
name=\"${ROOT_PART_NAME}\", start=${ROOT_START}M, size=${ROOT_SIZE}M, type=${root_type}
name=\"${SWAP_PART_NAME}\", start=${SWAP_START}M, size=${SWAP_SIZE_MIB}M, type=${swap_type}"
    
    log "Applying partition scheme..."
    printf "%s" "$sfdisk_input" | sudo sfdisk --wipe always --wipe-partitions always "$TARGET_DISK"
    
    # Inform kernel of changes
    sync
    sudo partprobe "$TARGET_DISK" || sudo blockdev --rereadpt "$TARGET_DISK" || true
    sleep 2
    
    log "Partition scheme applied successfully."
    sudo sfdisk -l "$TARGET_DISK"
}

format_partitions() {
    log "Formatting partitions..."
    
    # Wait for device nodes to be available
    local max_wait=10
    local wait_count=0
    while [[ ! -e "$EFI_DEVICE_NODE" || ! -e "$ROOT_DEVICE_NODE" || ! -e "$SWAP_DEVICE_NODE" ]] && [ $wait_count -lt $max_wait ]; do
        sleep 1
        ((wait_count++))
    done
    
    if [[ ! -e "$EFI_DEVICE_NODE" || ! -e "$ROOT_DEVICE_NODE" || ! -e "$SWAP_DEVICE_NODE" ]]; then
        log_error "Partition device nodes not available after waiting"
        exit 1
    fi
    
    # Format partitions
    log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"
    log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE"
    log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE"
    
    log "Partitions formatted successfully."
}

mount_filesystems() {
    log "Mounting filesystems..."
    
    # Mount root
    log_sudo_cmd mount "$ROOT_DEVICE_NODE" /mnt
    if ! mountpoint -q /mnt; then
        log_error "Failed to mount root filesystem"
        exit 1
    fi
    
    # Create and mount boot
    log_sudo_cmd mkdir -p /mnt/boot
    log_sudo_cmd mount "$EFI_DEVICE_NODE" /mnt/boot
    if ! mountpoint -q /mnt/boot; then
        log_error "Failed to mount EFI filesystem"
        exit 1
    fi
    
    # Enable swap
    log_sudo_cmd swapon "$SWAP_DEVICE_NODE"
    
    log "Filesystems mounted successfully."
    lsblk -fpo NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DISK"
}

# === Configuration Generation Functions ===
generate_flake_with_modules() {
    local template_file="$1"
    local output_file="$2"
    local module_imports="$3"
    local template_path="${TEMPLATE_DIR}/${template_file}"
    local output_path="${TARGET_NIXOS_CONFIG_DIR}/${output_file}"
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template file not found: $template_path"
        return 1
    fi
    
    log "Generating $output_file from template..."
    
    # Create temporary files for processing
    local temp_file1 temp_file2
    temp_file1=$(mktemp)
    temp_file2=$(mktemp)
    
    # First pass: substitute variables
    sed \
        -e "s|__NIXOS_USERNAME__|$(escape_for_sed "$NIXOS_USERNAME")|g" \
        -e "s|__PASSWORD_HASH__|$(escape_for_sed "$PASSWORD_HASH")|g" \
        -e "s|__GIT_USERNAME__|$(escape_for_sed "$GIT_USERNAME")|g" \
        -e "s|__GIT_USEREMAIL__|$(escape_for_sed "$GIT_USEREMAIL")|g" \
        -e "s|__HOSTNAME__|$(escape_for_sed "$HOSTNAME")|g" \
        -e "s|__TARGET_DISK_FOR_GRUB__|$(escape_for_sed "$TARGET_DISK")|g" \
        "$template_path" > "$temp_file1"
    
    # Second pass: inject module imports
    local placeholder="#__NIXOS_MODULE_IMPORTS_PLACEHOLDER__#"
    if grep -q "$placeholder" "$temp_file1"; then
        awk -v imports="$module_imports" -v placeholder="$placeholder" '
            {
                if ($0 ~ placeholder) {
                    print imports
                } else {
                    print $0
                }
            }
        ' "$temp_file1" > "$temp_file2"
    else
        cp "$temp_file1" "$temp_file2"
    fi
    
    # Install final file
    if sudo mv "$temp_file2" "$output_path"; then
        sudo chmod 644 "$output_path"
        log "$output_file generated successfully."
    else
        log_error "Failed to install $output_file"
        rm -f "$temp_file1" "$temp_file2"
        return 1
    fi
    
    rm -f "$temp_file1"
}

copy_nix_modules() {
    log "Copying NixOS module files..."
    
    for nix_file in "${TEMPLATE_DIR}"/*.nix; do
        if [[ -f "$nix_file" ]]; then
            local filename
            filename=$(basename "$nix_file")
            
            # Skip template files and hardware config
            if [[ "$filename" == "flake.nix.template" || "$filename" == "hardware-configuration.nix" ]]; then
                continue
            fi
            
            local dest_path="${TARGET_NIXOS_CONFIG_DIR}/${filename}"
            log "Copying $filename..."
            
            if sudo cp "$nix_file" "$dest_path"; then
                sudo chmod 644 "$dest_path"
            else
                log_error "Failed to copy $filename"
                exit 1
            fi
        fi
    done
}

generate_module_imports() {
    log "Generating dynamic module import list..."
    
    local imports=()
    while IFS= read -r -d '' module_file; do
        local filename
        filename=$(basename "$module_file")
        
        # Skip excluded files
        if [[ "$filename" == "flake.nix.template" ]] || \
           [[ "$filename" == "home-manager-user.nix" ]] || \
           [[ "$filename" == "hardware-configuration.nix" ]]; then
            continue
        fi
        
        imports+=("        ./${filename}")
    done < <(find "$TEMPLATE_DIR" -maxdepth 1 -name "*.nix" -type f -print0)
    
    # Join imports with newlines
    local import_string=""
    if [[ ${#imports[@]} -gt 0 ]]; then
        printf -v import_string '%s\n' "${imports[@]}"
        import_string=${import_string%?} # Remove trailing newline
    fi
    
    echo "$import_string"
}

# === User Input Functions ===
get_user_input() {
    log "Gathering user configuration..."
    
    # Show available disks
    show_available_disks
    echo ""
    
    # Get target disk
    while true; do
        read -r -p "Enter target disk (e.g., /dev/sda): " TARGET_DISK
        if [[ -b "$TARGET_DISK" ]]; then
            if confirm "Selected '$TARGET_DISK'. ALL DATA WILL BE ERASED! Continue?" "N"; then
                break
            fi
        else
            echo "Error: '$TARGET_DISK' is not a valid block device."
        fi
    done
    
    # Get username
    while [[ -z "$NIXOS_USERNAME" ]]; do
        read -r -p "Enter username: " NIXOS_USERNAME
    done
    
    # Get password
    while true; do
        read -r -s -p "Enter password: " pass1
        echo ""
        read -r -s -p "Confirm password: " pass2
        echo ""
        
        if [[ "$pass1" == "$pass2" && -n "$pass1" ]]; then
            PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 -s)
            if [[ -n "$PASSWORD_HASH" && "$PASSWORD_HASH" == \$6\$* ]]; then
                break
            else
                log_error "Failed to generate password hash"
                exit 1
            fi
        else
            echo "Passwords don't match or are empty. Try again."
        fi
    done
    unset pass1 pass2
    
    # Get Git configuration
    while [[ -z "$GIT_USERNAME" ]]; do
        read -r -p "Enter Git username: " GIT_USERNAME
    done
    
    while [[ -z "$GIT_USEREMAIL" ]]; do
        read -r -p "Enter Git email: " GIT_USEREMAIL
    done
    
    # Get hostname
    read -r -p "Enter hostname (default: nixos): " HOSTNAME
    HOSTNAME=${HOSTNAME:-nixos}
    
    # Show summary
    echo ""
    echo "Configuration Summary:"
    echo "  Target Disk:     $TARGET_DISK"
    echo "  Username:        $NIXOS_USERNAME"
    echo "  Git Username:    $GIT_USERNAME"
    echo "  Git Email:       $GIT_USEREMAIL"
    echo "  Hostname:        $HOSTNAME"
    echo "  EFI Size:        ${DEFAULT_EFI_SIZE_MiB}MiB"
    echo "  Swap Size:       ${SWAP_SIZE_GB}GiB"
    echo ""
    
    confirm "Proceed with these settings?" "Y"
}

# === Main Installation Functions ===
partition_and_format_disk() {
    log "Starting disk operations..."
    
    prepare_mount_points
    calculate_partitions
    
    # Turn off existing swap
    sudo swapoff -a 2>/dev/null || true
    
    create_partitions
    format_partitions
    mount_filesystems
    
    log "Disk operations completed successfully."
}

generate_nixos_config() {
    log "Generating NixOS configuration..."
    
    # Generate hardware configuration
    log_sudo_cmd nixos-generate-config --root /mnt
    
    # Remove default configuration.nix
    if [[ -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix" ]]; then
        sudo rm -f "${TARGET_NIXOS_CONFIG_DIR}/configuration.nix"
    fi
    
    # Ensure target directory exists
    log_sudo_cmd mkdir -p "$TARGET_NIXOS_CONFIG_DIR"
    
    # Copy module files
    copy_nix_modules
    
    # Generate module imports
    local module_imports
    module_imports=$(generate_module_imports)
    
    # Generate flake.nix
    generate_flake_with_modules "flake.nix.template" "flake.nix" "$module_imports"
    
    log "NixOS configuration generated successfully."
}

install_nixos() {
    log "Starting NixOS installation..."
    echo "This may take a long time. Please be patient."
    
    if confirm "Proceed with NixOS installation?" "Y"; then
        log "Running nixos-install..."
        
        # Run installation in background to show progress
        sudo nixos-install --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}" &
        local install_pid=$!
        
        show_progress $install_pid "Installing NixOS"
        
        if wait $install_pid; then
            log "NixOS installation completed successfully!"
            echo ""
            echo "======================================================================"
            echo "Installation Complete!"
            echo "======================================================================"
            echo ""
            echo "Your NixOS system has been installed successfully."
            echo "You can now:"
            echo "  1. Reboot into your new system: sudo reboot"
            echo "  2. Remove the installation media"
            echo "  3. Log in with username: $NIXOS_USERNAME"
            echo ""
            echo "Configuration files are located at: $TARGET_NIXOS_CONFIG_DIR"
            echo "Installation log: $LOG_FILE"
            echo ""
            confirm "Reboot now?" "Y" && sudo reboot
        else
            log_error "NixOS installation failed!"
            echo "Check the installation log: $LOG_FILE"
            exit 1
        fi
    fi
}

# === Main Script ===
main() {
    echo "======================================================================"
    echo "Enhanced NixOS Flake-based Installation Script"
    echo "======================================================================"
    echo ""
    echo "WARNING: This script will ERASE ALL DATA on the selected disk!"
    echo "         Please ensure you have backed up important data."
    echo ""
    echo "Installation log: $LOG_FILE"
    echo ""
    
    if ! confirm "Do you understand and accept full responsibility?" "N"; then
        echo "Installation aborted by user."
        exit 0
    fi
    
    log "Starting NixOS installation process..."
    
    # Check dependencies
    check_dependencies
    
    # Gather user input
    get_user_input
    
    # Partition and format disk
    partition_and_format_disk
    
    # Generate configuration
    generate_nixos_config
    
    # Install NixOS
    install_nixos
}

# Run main function
main "$@"

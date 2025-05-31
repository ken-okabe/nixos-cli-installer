#!/usr/bin/env bash

# === Initial Setup and Error Handling ===
set -euo pipefail # Exit immediately if a command exits with a non-zero status.
# set -x # Uncomment for extreme debugging (prints every command executed)

# Get the directory where the script is located to reference template files.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"
TARGET_NIXOS_CONFIG_DIR="/mnt/etc/nixos"                # NixOS config on the target mount
LOG_FILE="/tmp/nixos-install-$(date +%s).log"

# === Global Variables (ensure these are initialized) ===
NIXOS_USERNAME=""
PASSWORD_HASH=""
GIT_USERNAME=""
GIT_USEREMAIL=""
HOSTNAME=""
TARGET_DISK=""

EFI_DEVICE_NODE=""
ROOT_DEVICE_NODE=""
SWAP_DEVICE_NODE=""

EFI_START_MIB_CALC=""
EFI_SIZE_MIB_CALC=""
ROOT_START_MIB_CALC=""
ROOT_SIZE_MIB_CALC=""
SWAP_START_MIB_CALC=""
SWAP_SIZE_MIB_CALC=""

# Partition configuration (can be overridden by user input if that logic is added)
SWAP_SIZE_GB="16"
DEFAULT_EFI_SIZE_MiB="512"
EFI_PART_NAME="EFI"
SWAP_PART_NAME="SWAP"
ROOT_PART_NAME="ROOT_NIXOS"
DEFAULT_ROOT_FS_TYPE="ext4"


# === Logging Functions (from previous debugged version) ===
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | sudo tee -a "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" | sudo tee -a "$LOG_FILE" >&2
}

log_cmd() {
    log "CMD: $*"
    local status
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

# === Function Definitions (from user provided script, enhanced) ===
confirm() {
    local question="$1"
    local default_response_char="$2" # Expected to be "Y" or "N"
    local prompt_display=""

    if [[ "$default_response_char" == "Y" ]]; then
        prompt_display="[Y/n]"
    elif [[ "$default_response_char" == "N" ]]; then
        prompt_display="[y/N]"
    else
        log_error "DEVELOPER ERROR: confirm function called with invalid default_response_char: '$default_response_char'. Assuming 'N'."
        prompt_display="[y/N]"
        default_response_char="N"
    fi

    while true; do
        read -r -p "${question} ${prompt_display}: " response >&2
        local response_lower
        response_lower=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response_lower" in
            y|yes)
                return 0 # Success (Yes)
                ;;
            n|no)
                echo "You selected 'No'. For critical choices, this may abort or re-prompt. Press Ctrl+C to abort script if stuck." >&2
                # This confirm function itself will loop on 'no'.
                # If 'no' should lead to script termination, the calling code must handle it.
                ;;
            "") # Empty input, choose default
                if [[ "$default_response_char" == "Y" ]]; then
                    return 0 # Success (Default was Yes)
                else
                     echo "Default is 'No'. For critical choices, this may abort or re-prompt. Press Ctrl+C to abort script if stuck." >&2
                fi
                ;;
            *)
                echo "Invalid input. Please type 'y' (for yes) or 'n' (for no), or press Enter to accept the default." >&2
                ;;
        esac
    done
}

_escape_sed_replacement_string_singleline() {
    # Escapes for sed 's/pattern/replacement/' part, for single line values.
    # \ & / and newline are primary concerns for basic sed.
    # Added ' just in case delimiter is ' but usually we use | or %.
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/&/\\&/g' \
        -e 's/\//\\\//g' \
        -e "s/'/\\\\'/g" \
        -e 's/%/%%/g' # If % is used as delimiter in sed script
}

_escape_sed_pattern_string() {
    # Escapes for sed 's/pattern/replacement/' part, for the PATTERN.
    # Escapes characters that are special in BRE/ERE.
    printf '%s' "$1" | sed -e 's/[][\/.*^$]/\\&/g'
}

_escape_sed_replacement_string_multiline() {
    # For multi-line replacement, main concern is & \ and the delimiter.
    # Newlines should be literal newlines in the replacement string.
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e 's/&/\\&/g' \
        -e 's/%/%%/g' # Assuming % might be a sed delimiter
}

# User-provided generate_module_imports function
generate_module_imports() {
    local imports_array=()
    
    # カスタムモジュールファイルを検索
    if [[ -d "$TEMPLATE_DIR" ]]; then
        local copied_module_files
        # Ensure find errors (e.g. permission denied on TEMPLATE_DIR) don't break the script if not critical
        copied_module_files=$(find "$TEMPLATE_DIR" -maxdepth 1 -name "*.nix" -type f \
                                -not -name "flake.nix.template" \
                                -not -name "hardware-configuration.nix" 2>/dev/null || true) # Proceed even if find has minor errors

        if [[ -n "$copied_module_files" ]]; then
            while IFS= read -r module_path; do
                # Ensure module_path is not empty and is a file (find should ensure it's a file)
                if [[ -n "$module_path" && -f "$module_path" ]]; then 
                    local filename
                    filename=$(basename "$module_path")
                    imports_array+=("      ./${filename}") # 6 spaces indentation as per original
                fi
            done <<< "$copied_module_files"
        fi
    else
        log "Template directory '$TEMPLATE_DIR' not found, no custom modules will be imported other than hardware-configuration.nix."
    fi
    
    # hardware-configuration.nixを必ず追加
    imports_array+=("      ./hardware-configuration.nix") # 6 spaces indentation

    # 配列が空でないことを確認して文字列を生成
    local import_string=""
    if [[ ${#imports_array[@]} -gt 0 ]]; then
        # 最初の要素
        import_string="${imports_array[0]}"
        # 残りの要素を追加 (ループは要素が2つ以上の場合のみ実行)
        for ((i=1; i<${#imports_array[@]}; i++)); do
            import_string="$import_string"$'\n'"${imports_array[i]}"
        done
    else
        # フォールバック（imports_arrayにhw-configが入るので、通常ここには来ないはず）
        log_error "generate_module_imports: imports_array was unexpectedly empty. Defaulting to hardware-configuration.nix only."
        import_string="      ./hardware-configuration.nix"
    fi
    
    echo "$import_string"
}


generate_flake_with_modules() {
    local template_file_basename="$1" 
    local output_file_basename="$2"   
    local template_path="${TEMPLATE_DIR}/${template_file_basename}"
    local output_path_final="${TARGET_NIXOS_CONFIG_DIR}/${output_file_basename}"
    # nixos_module_imports_string is now generated inside this function by calling generate_module_imports
    
    if [[ ! -f "$template_path" ]]; then
        log_error "Template file not found: $template_path"
        return 1
    fi

    log "Generating dynamic NixOS module import list..."
    local nixos_module_imports_string
    nixos_module_imports_string=$(generate_module_imports) # Call the user-provided function
    log "Generated module import block for flake.nix will be:\n${nixos_module_imports_string}"


    log "Generating initial $output_file_basename from $template_path (pass 1 - variable substitution)..."
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
    trap "rm -f '$temp_output_pass1' 2>/dev/null" RETURN # Ensure temp file is cleaned up

    # Sed needs to read template_path, output to temp_output_pass1
    if ! sed "$sed_script_pass1_cmds" "${template_path}" > "${temp_output_pass1}"; then
        log_error "sed command (pass 1 - variable substitution) failed for ${output_file_basename}."
        return 1
    fi
    log "Pass 1 (variable substitution) for ${output_file_basename} successful."

    log "Inserting dynamic module list into ${output_file_basename} (pass 2 - module import injection)..."
    local placeholder_to_replace="#__NIXOS_MODULE_IMPORTS_PLACEHOLDER__#"
    local escaped_placeholder_pattern
    escaped_placeholder_pattern=$(_escape_sed_pattern_string "$placeholder_to_replace")
    
    local escaped_module_imports_for_sed_replacement
    escaped_module_imports_for_sed_replacement=$(_escape_sed_replacement_string_multiline "${nixos_module_imports_string}")

    local temp_output_pass2 sed_script_file_pass2
    temp_output_pass2=$(mktemp)
    sed_script_file_pass2=$(mktemp)
    # Ensure these additional temp files are also cleaned up
    trap "rm -f '$temp_output_pass1' '$temp_output_pass2' '$sed_script_file_pass2' 2>/dev/null" RETURN


    # Using % as delimiter for sed 's' command.
    printf 's%%%s%%%s%%g\n' "$escaped_placeholder_pattern" "$escaped_module_imports_for_sed_replacement" > "$sed_script_file_pass2"
    log "DEBUG: Sed script for pass 2 ($sed_script_file_pass2) content:"
    cat "$sed_script_file_pass2" | sudo tee -a "$LOG_FILE" >/dev/null


    if sed -f "$sed_script_file_pass2" "${temp_output_pass1}" > "${temp_output_pass2}"; then
        # Moving final file to /mnt needs sudo
        if sudo mv "$temp_output_pass2" "$output_path_final"; then
            log "${output_file_basename} generated successfully with dynamic modules at ${output_path_final}."
            sudo chmod 644 "$output_path_final"
            # Temp files cleaned by trap
            return 0
        else
            log_error "Failed to move final ${output_file_basename} to ${output_path_final}."
            # Temp files cleaned by trap
            return 1
        fi
    else
        log_error "sed command (pass 2 - module import injection) failed for ${output_file_basename}."
        # Temp files cleaned by trap
        return 1
    fi
}

# === Dependency Checking (from previous script) ===
# (Included above)

# === User Input Gathering (from previous script, with debug echoes) ===
# (This will be the get_user_input function from the previous turn where we added debug echoes)
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
    echo "DEBUG (get_user_input): TARGET_DISK='${TARGET_DISK}'" >&2 
    log "User confirmed target disk for installation: $TARGET_DISK" 

    while [[ -z "$NIXOS_USERNAME" ]]; do
        read -r -p "Enter username for the primary NixOS user: " NIXOS_USERNAME >&2
        if ! [[ "$NIXOS_USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ && ${#NIXOS_USERNAME} -le 32 ]]; then
            echo "Invalid username. Use lowercase letters, numbers, underscores, hyphens. Start with letter/underscore. Max 32 chars." >&2
            NIXOS_USERNAME="" 
        fi
    done
    echo "DEBUG (get_user_input): NIXOS_USERNAME='${NIXOS_USERNAME}'" >&2 
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
            # Using --stdin with mkpasswd from shadow-utils is a common way to pipe password
            PASSWORD_HASH=$(echo -n "$pass1" | mkpasswd -m sha-512 --stdin) 
            if [[ -n "$PASSWORD_HASH" && "$PASSWORD_HASH" == \$6\$* ]]; then 
                log "Password hash generated successfully for user $NIXOS_USERNAME." 
                break 
            else
                log_error "Failed to generate a valid password hash. mkpasswd output was: '$PASSWORD_HASH'"
                echo "Password hash generation failed. Please try again. Ensure 'mkpasswd' is from shadow utils and supports --stdin." >&2
            fi
        else
            echo "Passwords do not match. Please try again." >&2
        fi
    done
    unset pass1 pass2 
    echo "DEBUG (get_user_input): PASSWORD_HASH (first 10 chars)='${PASSWORD_HASH:0:10}...'" >&2 

    while [[ -z "$GIT_USERNAME" ]]; do
        read -r -p "Enter your Git username (for user's .gitconfig, e.g., 'Your Name'): " GIT_USERNAME >&2
    done
    echo "DEBUG (get_user_input): GIT_USERNAME='${GIT_USERNAME}'" >&2 
    log "Git username set to: $GIT_USERNAME" 
    
    while [[ -z "$GIT_USEREMAIL" ]]; do
        read -r -p "Enter your Git email (for user's .gitconfig): " GIT_USEREMAIL >&2
         if ! [[ "$GIT_USEREMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then 
            echo "Invalid email address format. Please try again." >&2
            GIT_USEREMAIL="" 
        fi
    done
    echo "DEBUG (get_user_input): GIT_USEREMAIL='${GIT_USEREMAIL}'" >&2 
    log "Git email set to: $GIT_USEREMAIL" 
    
    read -r -p "Enter hostname for the system (e.g., 'nixos-desktop', default: nixos): " HOSTNAME >&2
    HOSTNAME=${HOSTNAME:-nixos} 
    if ! [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        echo "Invalid hostname. Using 'nixos' as default." >&2
        HOSTNAME="nixos"
    fi
    echo "DEBUG (get_user_input): HOSTNAME='${HOSTNAME}'" >&2 
    log "Hostname set to: $HOSTNAME" 
    
    echo "" >&2
    echo "--- Configuration Summary (before final confirm) ---" >&2
    echo "  Target Disk:      $TARGET_DISK" >&2
    echo "  NixOS Username:   $NIXOS_USERNAME" >&2
    echo "  Password Hash:    (set)" >&2 
    echo "  Git Username:     $GIT_USERNAME" >&2
    echo "  Git Email:        $GIT_USEREMAIL" >&2
    echo "  Hostname:         $HOSTNAME" >&2
    echo "----------------------------------------------------" >&2
    echo "DEBUG (Final Check Values before confirm):" >&2
    echo "  TARGET_DISK='${TARGET_DISK}'" >&2
    echo "  NIXOS_USERNAME='${NIXOS_USERNAME}'" >&2
    echo "  PASSWORD_HASH (first 10 chars)='${PASSWORD_HASH:0:10}...'" >&2
    echo "  GIT_USERNAME='${GIT_USERNAME}'" >&2
    echo "  GIT_USEREMAIL='${GIT_USEREMAIL}'" >&2
    echo "  HOSTNAME='${HOSTNAME}'" >&2
    echo "----------------------------------------------------" >&2
    echo "" >&2
    
    if ! confirm "Review the summary above. Do you want to proceed with these settings?" "Y"; then
        log "User chose not to proceed with the current settings. Aborting."
        echo "Installation aborted by user." >&2
        exit 0 # Clean exit as per user choice
    fi
    log "User confirmed settings. Proceeding with partitioning." 
}


# === Disk Operation Functions (from previous debugged script) ===
# (calculate_partitions, create_partitions, format_partitions, mount_filesystems)
# (These were provided in full in the previous turn with logging fixes)
# (They will be inserted here in the final script)
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
    
    if ! log_sudo_cmd mkfs.vfat -F 32 -n "$EFI_PART_NAME" "$EFI_DEVICE_NODE"; then exit 1; fi
    if ! log_sudo_cmd mkfs."$DEFAULT_ROOT_FS_TYPE" -F -L "$ROOT_PART_NAME" "$ROOT_DEVICE_NODE"; then exit 1; fi
    if ! log_sudo_cmd mkswap -f -L "$SWAP_PART_NAME" "$SWAP_DEVICE_NODE"; then exit 1; fi
    
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
        log_error "Failed to mount root filesystem $ROOT_DEVICE_NODE on /mnt. Exiting."
        exit 1
    fi
    if ! mountpoint -q /mnt; then 
        log_error "Verification failed: /mnt is not a mountpoint after mount command. Exiting."
        exit 1
    fi
    
    if ! log_sudo_cmd mkdir -p /mnt/boot; then exit 1; fi

    log "Mounting EFI partition $EFI_DEVICE_NODE on /mnt/boot"
    if ! log_sudo_cmd mount "$EFI_DEVICE_NODE" /mnt/boot; then
        log_error "Failed to mount EFI filesystem $EFI_DEVICE_NODE on /mnt/boot. Exiting."
        # Attempt to unmount root before exiting
        sudo umount /mnt 2>/dev/null || true 
        exit 1
    fi
     if ! mountpoint -q /mnt/boot; then 
        log_error "Verification failed: /mnt/boot is not a mountpoint after mount command. Exiting."
        sudo umount /mnt 2>/dev/null || true 
        exit 1
    fi
    
    log "Enabling swap on $SWAP_DEVICE_NODE"
    if ! log_sudo_cmd swapon "$SWAP_DEVICE_NODE"; then
        log_error "Failed to enable swap on $SWAP_DEVICE_NODE. Continuing, but system may lack swap."
        # Not exiting for swap failure, but logging it.
    fi
    
    log "Filesystems mounted and swap enabled successfully."
    log "Current filesystem layout on $TARGET_DISK (output to console and log):"
    (set -o pipefail; sudo lsblk -fpo NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,PARTUUID "$TARGET_DISK" 2>&1 | sudo tee -a "$LOG_FILE")
}


# === Main Step Functions (from previous script) ===
partition_and_format_disk() {
    log "Starting disk partitioning and formatting operations for $TARGET_DISK..."
    prepare_mount_points 
    calculate_partitions 
    log "Turning off any existing swap devices on the system..."
    log_sudo_cmd swapoff -a || log_error "swapoff -a returned non-zero (this can often be ignored if no swap was active)." 
    create_partitions 
    format_partitions 
    mount_filesystems 
    log "Disk operations (partitioning, formatting, mounting) completed successfully."
}

generate_nixos_config() {
    log "Generating NixOS configuration files in $TARGET_NIXOS_CONFIG_DIR..."
    log "Running 'nixos-generate-config --root /mnt' to create hardware-configuration.nix..."
    if ! log_sudo_cmd nixos-generate-config --root /mnt; then
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
    
    if ! log_sudo_cmd mkdir -p "$TARGET_NIXOS_CONFIG_DIR"; then exit 1; fi
    copy_nix_modules # This function already uses log_sudo_cmd internally and exits on failure
    
    # The generate_flake_with_modules function will call generate_module_imports internally.
    log "Generating main flake.nix from template using generate_flake_with_modules..."
    if ! generate_flake_with_modules "flake.nix.template" "flake.nix"; then # Removed third argument
        log_error "Failed to generate flake.nix. Exiting." 
        exit 1
    fi
    
    log "NixOS configuration generation process completed."
    log "IMPORTANT NOTE FOR THE USER:" 
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
        log "User confirmed. Preparing to run nixos-install with options: -v --show-trace --no-root-passwd --flake ${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}"
        
        ( set -o pipefail; sudo nixos-install -v --show-trace --no-root-passwd --flake "${TARGET_NIXOS_CONFIG_DIR}#${HOSTNAME}" 2>&1 | sudo tee -a "$LOG_FILE" >/dev/null ) &
        local install_pid=$!
        log "nixos-install process started in background with PID $install_pid."
        
        show_progress $install_pid "Installing NixOS (PID: $install_pid)" 
        
        wait "$install_pid"
        local install_status=$? 

        if [ "$install_status" -eq 0 ]; then
            log "NixOS installation command (PID: $install_pid) completed successfully (exit status: 0)."
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
            log_error "NixOS installation command (PID: $install_pid) FAILED with exit status: $install_status."
            echo "" >&2
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "!!! NixOS Installation FAILED. Please check the log file:          !!!" >&2
            echo "!!!   $LOG_FILE                                                    !!!"
            echo "!!! The actual error from nixos-install (with -v and --show-trace) !!!"
            echo "!!! should be in this log, providing more details.                 !!!"
            echo "!!! You may also find more specific errors from nixos-install in:  !!!"
            echo "!!!   /mnt/var/log/nixos-install.log (if it was created on /mnt)   !!!"
            echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
            echo "" >&2
            echo "Common reasons for failure include (check log for specifics):" >&2
            echo "  - Network issues during package downloads." >&2
            echo "  - Errors in your custom NixOS configuration/flake." >&2
            echo "  - Insufficient disk space or memory." >&2
            echo "  - Hardware compatibility issues." >&2
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
    # Sudo privilege check
    if [[ $EUID -ne 0 ]]; then 
        if ! sudo -n true 2>/dev/null; then # Check if passwordless sudo is possible
            echo "This script requires sudo privileges. Attempting to acquire..." >&2
            if ! sudo true; then # Prompt for password
                echo "Failed to acquire sudo privileges. Please run with sudo or ensure passwordless sudo is configured. Exiting." >&2
                exit 1
            fi
            echo "Sudo privileges acquired." >&2
        else
             # This case means EUID != 0 but `sudo -n true` succeeded (passwordless sudo)
             log "Script not run as root, but passwordless sudo is available or not needed for 'sudo true'."
        fi
    else
        log "Script is running as root."
    fi

    # Initialize log file (truncate/create as root)
    echo "Initializing NixOS Installation Script. Log file: $LOG_FILE" | sudo tee "$LOG_FILE" >/dev/null 
    
    # --- Script Header / Warning ---
    log "======================================================================" # Logged
    log "      Enhanced NixOS Flake-based Installation Script                  "
    log "======================================================================"
    echo "" >&2 # Console only
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

    log "Main script execution sequence finished (or user chose not to reboot/poweroff yet)."
}

# --- Run Main Function ---
main "$@"

exit 0
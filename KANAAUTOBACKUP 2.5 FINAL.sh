#!/bin/bash

### CONFIGURATION ###
TODAY=$(date +'%Y-%m-%d')
RCLONE_CONFIG_PATH="/root/.config/rclone/rclone.conf"
RCLONE_REMOTE="kanaautobackup"
ICLOUD_REMOTE="icloud_backup"
BACKUP_HOST="139.180.210.60"
REMOTE_USER="root"
LOG_FILE="/var/log/backup_${TODAY}.log"
COMPRESSION_LEVEL=6
MAX_PARALLEL=3
MIN_SIZE=1000000
REQUIRED_DEPS=("sshpass" "rclone" "pv" "pigz" "rsync" "numfmt")
DRY_RUN=false
DEBUG=false

export RCLONE_CONFIG="$RCLONE_CONFIG_PATH"

### VPS CONFIGURATION ###
declare -A VPS_IPS=(
    ["SGP1"]="178.128.16.199"
    ["PVN_Premi1"]="167.172.77.159"
    ["PVN_Borel"]="188.166.243.110"
    ["PVN_ZAVIRE"]="143.198.84.235"
    ["SGP7_MEDIUM_NEW"]="167.99.76.193"
    ["SGP2_MEDIUM_NEW"]="165.232.169.92"
    ["MISEL"]="152.42.181.232"
)

declare -A VPS_PASSWORDS=(
    ["SGP1"]="Admin123AS"
    ["PVN_Premi1"]="Admin123AS"
    ["PVN_Borel"]="Admin123AS"
    ["PVN_ZAVIRE"]="Admin123AS"
    ["SGP7_MEDIUM_NEW"]="Admin123AS"
    ["SGP2_MEDIUM_NEW"]="Admin123AS"
    ["MISEL"]="Admin123AS"
)

### FUNCTIONS ###
log() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$timestamp - $message" | tee -a "$LOG_FILE"
    if $DEBUG; then
        echo "$timestamp - [DEBUG] $message" >&2
    fi
}

clean_remote_path() {
    local remote="$1"
    local path="$2"
    
    log "🧹 Cleaning remote path ${remote}:${path}"
    
    # First try to delete if it's a file
    if rclone lsf "${remote}:${path}" --max-depth 0 2>/dev/null | grep -q "^.*[^/]$"; then
        log "ℹ️ Path exists as file, deleting..."
        if rclone deletefile "${remote}:${path}"; then
            log "✅ File deleted successfully"
            return 0
        fi
    fi
    
    # Then try purging if it's a directory or if delete failed
    log "ℹ️ Attempting to purge path..."
    if rclone purge "${remote}:${path}"; then
        log "✅ Path purged successfully"
        return 0
    fi
    
    log "❌ Failed to clean path"
    return 1
}

check_icloud_remote() {
    if ! rclone listremotes | grep -q "^${ICLOUD_REMOTE}:"; then
        log "⚠️ iCloud+ remote not configured"
        return 1
    fi
    return 0
}

upload_to_icloud() {
    local name="$1"
    local file_path="$2"
    local cloud_folder="backups-kanacloud/$name"
    local filename=$(basename "$file_path")
    
    if ! check_icloud_remote; then
        log "❌ [$name] iCloud+ backup skipped"
        return 1
    fi
    
    log "☁️ [$name] Uploading to iCloud+..."
    
    # Ensure directory structure exists
    if ! rclone mkdir "${ICLOUD_REMOTE}:backups-kanacloud" 2>/dev/null; then
        log "⚠️ [$name] Base directory already exists"
    fi
    
    if ! rclone mkdir "${ICLOUD_REMOTE}:${cloud_folder}" 2>/dev/null; then
        log "⚠️ [$name] Target directory already exists"
    fi
    
    # Upload with retries
    local max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if $DRY_RUN; then
            log "ℹ️ DRY RUN: Would upload to ${ICLOUD_REMOTE}:${cloud_folder}/${filename}"
            return 0
        fi
        
        log "🔄 [$name] Attempt $attempt/$max_attempts"
        if rclone copyto "$file_path" "${ICLOUD_REMOTE}:${cloud_folder}/${filename}" \
           --progress --stats-one-line --retries 1; then
            
            if rclone check "$file_path" "${ICLOUD_REMOTE}:${cloud_folder}/${filename}" --size-only; then
                log "✅ [$name] Upload successful"
                return 0
            else
                log "❌ [$name] Verification failed"
            fi
        else
            log "❌ [$name] Upload failed"
        fi
        
        sleep $((attempt * 5))
    done
    
    log "❌ [$name] All attempts failed"
    return 1
}

get_available_storage() {
    local required_size=$1
    local selected_storage=""
    
    # First check root
    local root_avail=$(df -B1 / | awk 'NR==2 {print $4}')
    if (( root_avail > required_size )); then
        echo "/"
        return
    fi
    
    # Then check /mnt partitions
    local mnt_partitions=($(ls -d /mnt/* 2>/dev/null))
    if [[ ${#mnt_partitions[@]} -eq 0 ]]; then
        echo ""
        return
    fi
    
    # Randomize the order of partitions
    mnt_partitions=($(shuf -e "${mnt_partitions[@]}"))
    
    for storage in "${mnt_partitions[@]}"; do
        if [ -d "$storage" ]; then
            local avail=$(df -B1 "$storage" | awk 'NR==2 {print $4}')
            if (( avail > required_size )); then
                echo "$storage"
                return
            fi
        fi
    done
    
    echo ""
}

upload_to_drive() {
    local name="$1"
    local file_path="$2"
    local drive_folder="backups-kanacloud/$name"
    local filename=$(basename "$file_path")
    
    log "☁️ [$name] Preparing Google Drive upload..."

    # Clean existing paths if needed
    if rclone lsf "$RCLONE_REMOTE:$drive_folder" 2>/dev/null | grep -q "^.*[^/]$"; then
        log "⚠️ Target exists as file, cleaning..."
        clean_remote_path "$RCLONE_REMOTE" "$drive_folder"
    fi
    
    # Create directory structure
    if ! rclone mkdir "$RCLONE_REMOTE:backups-kanacloud" 2>/dev/null; then
        log "⚠️ Base directory already exists"
    fi
    
    if ! rclone mkdir "$RCLONE_REMOTE:$drive_folder" 2>/dev/null; then
        log "⚠️ Target directory already exists"
    fi
    
    # Check for existing file
    if rclone lsf "$RCLONE_REMOTE:$drive_folder/$filename" 2>/dev/null; then
        log "⚠️ File exists, removing..."
        if ! rclone deletefile "$RCLONE_REMOTE:$drive_folder/$filename"; then
            log "❌ Could not remove existing file"
            return 1
        fi
    fi
    
    # Upload with retries
    local max_attempts=3
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if $DRY_RUN; then
            log "ℹ️ DRY RUN: Would upload to $RCLONE_REMOTE:$drive_folder/$filename"
            return 0
        fi
        
        log "🔄 [$name] Attempt $attempt/$max_attempts"
        if rclone copyto "$file_path" "$RCLONE_REMOTE:$drive_folder/$filename" \
           --progress --stats-one-line --retries 1; then
            
            if rclone check "$file_path" "$RCLONE_REMOTE:$drive_folder/$filename" --size-only; then
                log "✅ [$name] Upload successful"
                return 0
            else
                log "❌ [$name] Verification failed"
            fi
        else
            log "❌ [$name] Upload failed"
        fi
        
        sleep $((attempt * 5))
    done
    
    log "❌ [$name] All attempts failed"
    return 1
}

perform_live_sync() {
    local name="$1"
    local remote_host="$2"
    local remote_pass="$3"
    local remote_dir="/backup_storage/$name"
    
    log "🔁 [$name] Starting live sync process..."
    
    # Create temporary local directory
    local_temp_dir=$(mktemp -d)
    log "📂 [$name] Created temp dir: $local_temp_dir"
    
    # Sync from source remote to local
    log "⬇️ [$name] Syncing from source to local..."
    if ! rsync -avz --progress -e "sshpass -p $remote_pass ssh -o StrictHostKeyChecking=no" \
        "$REMOTE_USER@$remote_host:/var/lib/pterodactyl/volumes/" \
        "$local_temp_dir/"; then
        log "❌ [$name] Failed to sync from source to local"
        rm -rf "$local_temp_dir"
        return 1
    fi
    
    # Sync from local to destination remote
    log "⬆️ [$name] Syncing from local to VPS Host..."
    if ! rsync -avz --progress -e "sshpass -p $remote_pass ssh -o StrictHostKeyChecking=no" \
        "$local_temp_dir/" \
        "$REMOTE_USER@$BACKUP_HOST:$remote_dir/live_sync/"; then
        log "❌ [$name] Failed to sync from local to destination"
        rm -rf "$local_temp_dir"
        return 1
    fi
    
    # Clean up temp dir
    rm -rf "$local_temp_dir"
    log "✅ [$name] Live sync completed successfully"
    return 0
}

compress_and_upload() {
    local name="$1"
    local remote_host="$2"
    local remote_pass="$3"
    local mode="$4"
    local filename="${name}_pterodactyl_${TODAY}.tar.gz"
    local temp_dir=""
    local local_temp=""
    local remote_dir="/backup_storage/$name"
    
    log "🔍 [$name] Checking available storage..."
    
    local size=$(sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$remote_host" \
        'du -sb /var/lib/pterodactyl/volumes 2>/dev/null | awk "{print \$1}"')
    
    if [[ -z "$size" ]]; then
        log "❌ [$name] Failed to get data size"
        return 1
    fi
    
    local required_size=$((size * 11 / 10))
    temp_dir=$(get_available_storage "$required_size")
    
    if [ -z "$temp_dir" ]; then
        log "❌ [$name] No storage available with $required_size bytes free"
        return 1
    fi
    
    local_temp="${temp_dir%/}/$filename"
    log "💾 [$name] Using storage: $temp_dir (Free: $(df -h $temp_dir | awk 'NR==2 {print $4}'))"
    
    log "📦 [$name] Compressing data (Size: $(numfmt --to=iec $size))..."
    if ! sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$remote_host" \
        "tar -cf - /var/lib/pterodactyl/volumes 2>/dev/null" | \
        pv -s "$size" | \
        pigz -p $(nproc) -${COMPRESSION_LEVEL} > "$local_temp"; then
        log "❌ [$name] Compression failed"
        rm -f "$local_temp" 2>/dev/null
        return 1
    fi
    
    if ! gzip -t "$local_temp"; then
        log "❌ [$name] Archive corrupted"
        rm -f "$local_temp"
        return 1
    fi
    
    local archive_size=$(du -h "$local_temp" | awk '{print $1}')
    log "✅ [$name] Archive created (Size: $archive_size)"

    case "$mode" in
        "vps-only")
            log "📤 [$name] Uploading to VPS Host..."
            if sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$BACKUP_HOST" \
                "mkdir -p '$remote_dir'"; then
                if ! rsync -avz --progress -e "sshpass -p $remote_pass ssh -o StrictHostKeyChecking=no" \
                    "$local_temp" "$REMOTE_USER@$BACKUP_HOST:$remote_dir/"; then
                    log "❌ [$name] Failed to upload to VPS Host"
                fi
            fi
            
            perform_live_sync "$name" "$remote_host" "$remote_pass"
            ;;
            
        "drive-only")
            upload_to_drive "$name" "$local_temp"
            ;;
            
        "icloud-only")
            upload_to_icloud "$name" "$local_temp"
            ;;
            
        "both")
            log "📤 [$name] Uploading to VPS Host..."
            if sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$BACKUP_HOST" \
                "mkdir -p '$remote_dir'"; then
                if ! rsync -avz --progress -e "sshpass -p $remote_pass ssh -o StrictHostKeyChecking=no" \
                    "$local_temp" "$REMOTE_USER@$BACKUP_HOST:$remote_dir/"; then
                    log "❌ [$name] Failed to upload to VPS Host"
                fi
            fi
            
            upload_to_drive "$name" "$local_temp"
            perform_live_sync "$name" "$remote_host" "$remote_pass"
            ;;
            
        "all")
            log "📤 [$name] Uploading to VPS Host..."
            if sshpass -p "$remote_pass" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$BACKUP_HOST" \
                "mkdir -p '$remote_dir'"; then
                if ! rsync -avz --progress -e "sshpass -p $remote_pass ssh -o StrictHostKeyChecking=no" \
                    "$local_temp" "$REMOTE_USER@$BACKUP_HOST:$remote_dir/"; then
                    log "❌ [$name] Failed to upload to VPS Host"
                fi
            fi
            
            upload_to_drive "$name" "$local_temp"
            upload_to_icloud "$name" "$local_temp"
            perform_live_sync "$name" "$remote_host" "$remote_pass"
            ;;
    esac
    
    rm -f "$local_temp"
    log "🧹 [$name] Temporary file removed"
}

backup_vps() {
    local name="$1"
    local mode="$2"
    
    if [[ -z "${VPS_IPS[$name]}" ]]; then
        log "❌ [$name] VPS not found in configuration"
        return 1
    fi
    
    log "🚀 [$name] Starting backup process (Mode: $mode)"
    compress_and_upload "$name" "${VPS_IPS[$name]}" "${VPS_PASSWORDS[$name]}" "$mode"
    log "🏁 [$name] Backup process completed"
}

show_monitor() {
    clear
    echo "===== BACKUP MONITOR ====="
    echo "Current time: $(date)"
    echo "Active backup processes:"
    ps aux | grep -E 'sshpass|rsync|rclone|tar|pigz|pv' | grep -v grep
    echo
    echo "Disk usage:"
    df -h
    echo
    read -p "Press Enter to return to menu..."
}

check_dependencies() {
    local missing=()
    
    for dep in "${REQUIRED_DEPS[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "The following dependencies are missing:"
        for dep in "${missing[@]}"; do
            echo " - $dep"
        done
        return 1
    fi
    return 0
}

install_dependencies() {
    echo "===== INSTALLING DEPENDENCIES ====="
    
    if command -v apt &> /dev/null; then
        apt update
        apt install -y sshpass rclone pv pigz rsync coreutils
    elif command -v yum &> /dev/null; then
        yum install -y epel-release
        yunit install -y sshpass rclone pv pigz rsync coreutils
    elif command -v dnf &> /dev/null; then
        dnf install -y sshpass rclone pv pigz rsync coreutils
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm sshpass rclone pv pigz rsync coreutils
    else
        echo "❌ Unsupported package manager"
        return 1
    fi
    
    if check_dependencies; then
        echo "✅ All dependencies installed"
    else
        echo "❌ Some dependencies failed to install"
        return 1
    fi
}

clean_remote_menu() {
    echo "Enter remote path to clean (e.g., backups-kanacloud/MISEL):"
    read -r path
    log "🧹 Cleaning $RCLONE_REMOTE:$path"
    
    if rclone purge "$RCLONE_REMOTE:$path"; then
        log "✅ Cleanup successful"
    else
        log "❌ Cleanup failed"
    fi
    read -p "Press Enter to continue..."
}

select_vps() {
    clear
    echo "===== SELECT VPS TO BACKUP ====="
    local i=1
    local vps_names=()
    
    for vps in "${!VPS_IPS[@]}"; do
        echo "$i) $vps (${VPS_IPS[$vps]})"
        vps_names[$i]="$vps"
        ((i++))
    done
    
    echo
    echo "$i) Back to main menu"
    echo
    read -p "Select VPS [1-$i]: " choice
    
    if (( choice == i )); then
        return
    elif (( choice >= 1 && choice < i )); then
        selected_vps="${vps_names[$choice]}"
        return 0
    else
        echo "Invalid selection!"
        sleep 1
        return 1
    fi
}

show_menu() {
    clear
    echo "======================================"
    echo "  KANACLOUD BACKUP SYSTEM 2.5 - $(date)"
    echo "======================================"
    echo
    echo "1) Backup to VPS Host only"
    echo "2) Backup to Google Drive only"
    echo "3) Backup to iCloud+ only"
    echo "4) Backup to both VPS Host and Google Drive"
    echo "5) Backup to all destinations (VPS, Drive, iCloud+)"
    echo "6) Monitor running backups"
    echo "7) View configuration"
    echo "8) Install Dependencies"
    echo "9) Clean Remote Path"
    echo "10) Select Specific VPS"
    echo "11) Exit"
    echo
    echo "Current selection: ${selected_vps:-All VPS}"
    echo
    read -p "Enter choice [1-11]: " choice
}

### MAIN EXECUTION ###
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

if ! check_dependencies; then
    echo "⚠️ Some dependencies are missing"
    sleep 3
fi

selected_vps=""

while true; do
    show_menu
    case $choice in
        1)
            log "🚀 Initializing VPS Host backup"
            if [[ -n "$selected_vps" ]]; then
                backup_vps "$selected_vps" "vps-only"
            else
                PIDS=()
                for name in "${!VPS_IPS[@]}"; do
                    backup_vps "$name" "vps-only" &
                    PIDS+=($!)
                    while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
                        sleep 5
                    done
                done
                for pid in "${PIDS[@]}"; do
                    wait "$pid"
                done
            fi
            read -p "Press Enter to continue..."
            ;;
        2)
            log "🚀 Initializing Google Drive backup"
            if [[ -n "$selected_vps" ]]; then
                backup_vps "$selected_vps" "drive-only"
            else
                PIDS=()
                for name in "${!VPS_IPS[@]}"; do
                    backup_vps "$name" "drive-only" &
                    PIDS+=($!)
                    while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
                        sleep 5
                    done
                done
                for pid in "${PIDS[@]}"; do
                    wait "$pid"
                done
            fi
            read -p "Press Enter to continue..."
            ;;
        3)
            log "🚀 Initializing iCloud+ backup"
            if [[ -n "$selected_vps" ]]; then
                backup_vps "$selected_vps" "icloud-only"
            else
                PIDS=()
                for name in "${!VPS_IPS[@]}"; do
                    backup_vps "$name" "icloud-only" &
                    PIDS+=($!)
                    while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
                        sleep 5
                    done
                done
                for pid in "${PIDS[@]}"; do
                    wait "$pid"
                done
            fi
            read -p "Press Enter to continue..."
            ;;
        4)
            log "🚀 Initializing backup to VPS Host and Google Drive"
            if [[ -n "$selected_vps" ]]; then
                backup_vps "$selected_vps" "both"
            else
                PIDS=()
                for name in "${!VPS_IPS[@]}"; do
                    backup_vps "$name" "both" &
                    PIDS+=($!)
                    while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
                        sleep 5
                    done
                done
                for pid in "${PIDS[@]}"; do
                    wait "$pid"
                done
            fi
            read -p "Press Enter to continue..."
            ;;
        5)
            log "🚀 Initializing backup to all destinations"
            if [[ -n "$selected_vps" ]]; then
                backup_vps "$selected_vps" "all"
            else
                PIDS=()
                for name in "${!VPS_IPS[@]}"; do
                    backup_vps "$name" "all" &
                    PIDS+=($!)
                    while [[ $(jobs -rp | wc -l) -ge $MAX_PARALLEL ]]; do
                        sleep 5
                    done
                done
                for pid in "${PIDS[@]}"; do
                    wait "$pid"
                done
            fi
            read -p "Press Enter to continue..."
            ;;
        6) show_monitor ;;
        7)
            clear
            echo "===== CONFIGURATION ====="
            echo "Backup Host: $BACKUP_HOST"
            echo "Remote User: $REMOTE_USER"
            echo "Rclone Remote: $RCLONE_REMOTE"
            echo "Compression Level: $COMPRESSION_LEVEL"
            echo "Max Parallel: $MAX_PARALLEL"
            echo "Log File: $LOG_FILE"
            echo
            echo "===== VPS LIST ====="
            for vps in "${!VPS_IPS[@]}"; do
                echo "- $vps (${VPS_IPS[$vps]})"
            done
            read -p "Press Enter to continue..."
            ;;
        8)
            install_dependencies
            read -p "Press Enter to continue..."
            ;;
        9)
            clean_remote_menu
            ;;
        10)
            select_vps
            ;;
        11)
            log "🛑 Script terminated by user"
            exit 0
            ;;
        *)
            echo "Invalid option!"
            sleep 1
            ;;
    esac
done
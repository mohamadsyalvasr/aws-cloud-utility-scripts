#!/bin/bash
# efs_report.sh
# Gathers a report on all EFS file systems, including size and status details.

set -euo pipefail

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/efs_report.csv"

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq, bc)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found. Please install it first."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found. Please install it first."
        exit 1
    fi
    if ! command -v bc >/dev/null 2>&1; then
        log "❌ bc not found. Please install it first."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Helper: Convert bytes to human-readable GiB ---
bytes_to_gib() {
    local bytes="$1"
    if [[ -z "$bytes" || "$bytes" == "N/A" || "$bytes" == "null" || "$bytes" == "0" ]]; then
        echo "0.00"
    else
        echo "scale=2; $bytes / 1073741824" | bc
    fi
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header - sizes are in GiB
printf '"Name","File System ID","Encrypted","Total Size (GiB)","Size in Standard (GiB)","Size in IA (GiB)","Size in Archive (GiB)","File System State","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get a list of all EFS file systems in the region
    EFS_DATA=$(aws efs describe-file-systems --region "$region" --output json)
    
    if [[ "$(echo "$EFS_DATA" | jq '.FileSystems // [] | length')" -gt 0 ]]; then
        echo "$EFS_DATA" | jq -c '.FileSystems[]' | while read -r fs_info; do
            NAME=$(echo "$fs_info" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
            FILE_SYSTEM_ID=$(echo "$fs_info" | jq -r '.FileSystemId')
            ENCRYPTED=$(echo "$fs_info" | jq -r '.Encrypted')
            STATE=$(echo "$fs_info" | jq -r '.LifeCycleState')
            CREATED_DATE=$(echo "$fs_info" | jq -r '.CreationTime')
            
            # Extract size data (in Bytes) and convert to GiB
            TOTAL_SIZE_BYTES=$(echo "$fs_info" | jq -r '.SizeInBytes.Value // "0"')
            STANDARD_SIZE_BYTES=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInStandard // "0"')
            IA_SIZE_BYTES=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInIA // "0"')
            ARCHIVE_SIZE_BYTES=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInArchive // "0"')

            TOTAL_SIZE_GIB=$(bytes_to_gib "$TOTAL_SIZE_BYTES")
            STANDARD_SIZE_GIB=$(bytes_to_gib "$STANDARD_SIZE_BYTES")
            IA_SIZE_GIB=$(bytes_to_gib "$IA_SIZE_BYTES")
            ARCHIVE_SIZE_GIB=$(bytes_to_gib "$ARCHIVE_SIZE_BYTES")
            
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$FILE_SYSTEM_ID" \
                "$ENCRYPTED" \
                "$TOTAL_SIZE_GIB" \
                "$STANDARD_SIZE_GIB" \
                "$IA_SIZE_GIB" \
                "$ARCHIVE_SIZE_GIB" \
                "$STATE" \
                "$CREATED_DATE" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [EFS] No file systems found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

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
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/efs_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found. Please install it first."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found. Please install it first."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Name","File system ID","Encrypted","Total size","Size in EFS Standard","Size in EFS IA","Size in Archive","File system state","Creation time"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get a list of all EFS file systems in the region
    EFS_DATA=$(aws efs describe-file-systems --region "$region" --output json)
    
    # Use the `// []` trick to provide an empty array if `FileSystems` is null
    if [[ "$(echo "$EFS_DATA" | jq '.FileSystems // [] | length')" -gt 0 ]]; then
        echo "$EFS_DATA" | jq -c '.FileSystems[]' | while read -r fs_info; do
            NAME=$(echo "$fs_info" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
            FILE_SYSTEM_ID=$(echo "$fs_info" | jq -r '.FileSystemId')
            ENCRYPTED=$(echo "$fs_info" | jq -r '.Encrypted')
            STATE=$(echo "$fs_info" | jq -r '.LifeCycleState')
            CREATED_DATE=$(echo "$fs_info" | jq -r '.CreationTime')
            
            # Extract and process size data from the `describe-file-systems` output
            TOTAL_SIZE=$(echo "$fs_info" | jq -r '.SizeInBytes.Value // "N/A"')
            STANDARD_SIZE=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInStandard // "N/A"')
            IA_SIZE=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInInfrequentAccess // "N/A"')
            ARCHIVE_SIZE="N/A" # This metric is not available in the API response
            
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$FILE_SYSTEM_ID" \
                "$ENCRYPTED" \
                "$TOTAL_SIZE" \
                "$STANDARD_SIZE" \
                "$IA_SIZE" \
                "$ARCHIVE_SIZE" \
                "$STATE" \
                "$CREATED_DATE" >> "$OUTPUT_FILE"
        done
    else
        log "  [EFS] No file systems found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

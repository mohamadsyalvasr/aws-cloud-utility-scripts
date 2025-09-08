#!/bin/bash
# efs_report.sh
# Gathers a report on all EFS file systems, including size and status details.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/efs_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: efs_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script Logic ---
main() {
    check_dependencies
    
    while getopts "r:f:h" opt; do
        case "$opt" in
            r)
                IFS=',' read -r -a REGIONS <<< "$OPTARG"
                ;;
            f)
                OUTPUT_FILE="$OPTARG"
                ;;
            h)
                usage
                ;;
            *)
                usage
                ;;
        esac
    done
    shift $((OPTIND-1))

    log "✍️ Preparing output file: $OUTPUT_FILE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"

    # Create CSV header
    printf '"Name","File system ID","Encrypted","Total size","Size in EFS Standard","Size in EFS IA","Size in Archive","File system state","Creation time"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local efs_data=$(aws efs describe-file-systems --region "$region" --output json)
        
        if [[ "$(echo "$efs_data" | jq '.FileSystems // [] | length')" -gt 0 ]]; then
            echo "$efs_data" | jq -c '.FileSystems[]' | while read -r fs_info; do
                local name=$(echo "$fs_info" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
                local file_system_id=$(echo "$fs_info" | jq -r '.FileSystemId')
                local encrypted=$(echo "$fs_info" | jq -r '.Encrypted')
                local state=$(echo "$fs_info" | jq -r '.LifeCycleState')
                local created_date=$(echo "$fs_info" | jq -r '.CreationTime')
                
                # Extract and process size data
                local total_size=$(echo "$fs_info" | jq -r '.SizeInBytes.Value // "N/A"')
                local standard_size=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInStandard // "N/A"')
                local ia_size=$(echo "$fs_info" | jq -r '.SizeInBytes.ValueInInfrequentAccess // "N/A"')
                local archive_size="N/A" # This metric is not available in the API response

                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$name" \
                    "$file_system_id" \
                    "$encrypted" \
                    "$total_size" \
                    "$standard_size" \
                    "$ia_size" \
                    "$archive_size" \
                    "$state" \
                    "$created_date" >> "$OUTPUT_FILE"
            done
        else
            log "  [EFS] No file systems found."
        fi

        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
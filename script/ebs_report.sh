#!/bin/bash
# ebs_report.sh
# Generates a detailed report on EBS volumes with custom columns.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/ebs_report_$(date +"%Y%m%d-%H%M%S").csv"

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
                   Default: ebs_report_<timestamp>.csv
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

    # Create CSV header with the requested columns
    printf '"Name","Volume ID","Type","Size","IOPS","Throughput","Snapshot ID","Created","Availability Zone","Volume state","Region"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local volumes_data=$(aws ec2 describe-volumes --region "$region" --query 'Volumes[]' --output json)

        if [[ "$(echo "$volumes_data" | jq 'length')" -gt 0 ]]; then
            echo "$volumes_data" | jq -c '.[]' | while read -r volume; do
                local name=$(echo "$volume" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
                local volume_id=$(echo "$volume" | jq -r '.VolumeId')
                local volume_type=$(echo "$volume" | jq -r '.VolumeType')
                local size=$(echo "$volume" | jq -r '.Size')
                local iops=$(echo "$volume" | jq -r '.Iops // "N/A"')
                local throughput=$(echo "$volume" | jq -r '.Throughput // "N/A"')
                local snapshot_id=$(echo "$volume" | jq -r '.SnapshotId // "N/A"')
                local created_time=$(echo "$volume" | jq -r '.CreateTime')
                local availability_zone=$(echo "$volume" | jq -r '.AvailabilityZone')
                local volume_state=$(echo "$volume" | jq -r '.State')

                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$name" \
                    "$volume_id" \
                    "$volume_type" \
                    "$size" \
                    "$iops" \
                    "$throughput" \
                    "$snapshot_id" \
                    "$created_time" \
                    "$availability_zone" \
                    "$volume_state" \
                    "$region" >> "$OUTPUT_FILE"
            done
        else
            log "  [EBS] No volumes found."
        fi

        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
#!/bin/bash
# ebs_detailed_report.sh
# Generates a detailed report on EBS volumes with custom columns.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="../output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/ebs_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

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
printf '"Name","Volume ID","Type","Size","IOPS","Throughput","Snapshot ID","Created","Availability Zone","Volume state"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    VOLUMES_DATA=$(aws ec2 describe-volumes --region "$region" --query 'Volumes[]' --output json)

    if [[ "$(echo "$VOLUMES_DATA" | jq 'length')" -gt 0 ]]; then
        echo "$VOLUMES_DATA" | jq -c '.[]' | while read -r volume; do
            NAME=$(echo "$volume" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
            VOLUME_ID=$(echo "$volume" | jq -r '.VolumeId')
            VOLUME_TYPE=$(echo "$volume" | jq -r '.VolumeType')
            SIZE=$(echo "$volume" | jq -r '.Size')
            IOPS=$(echo "$volume" | jq -r '.Iops // "N/A"')
            THROUGHPUT=$(echo "$volume" | jq -r '.Throughput // "N/A"')
            SNAPSHOT_ID=$(echo "$volume" | jq -r '.SnapshotId // "N/A"')
            CREATED_TIME=$(echo "$volume" | jq -r '.CreateTime')
            AVAILABILITY_ZONE=$(echo "$volume" | jq -r '.AvailabilityZone')
            VOLUME_STATE=$(echo "$volume" | jq -r '.State')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$VOLUME_ID" \
                "$VOLUME_TYPE" \
                "$SIZE" \
                "$IOPS" \
                "$THROUGHPUT" \
                "$SNAPSHOT_ID" \
                "$CREATED_TIME" \
                "$AVAILABILITY_ZONE" \
                "$VOLUME_STATE" >> "$OUTPUT_FILE"
        done
    else
        log "  [EBS] No volumes found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"
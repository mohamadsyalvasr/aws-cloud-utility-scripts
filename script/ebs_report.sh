#!/bin/bash
# ebs_report.sh
# Generates a report on EBS volumes, showing attachment status, disk size, and utilization metrics.

set -euo pipefail

# --- Configuration and Arguments ---
OUTPUT_FILE="ebs_report_$(date +"%Y%m%d-%H%M%S").csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for utilization metrics (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for utilization metrics (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions to scan. Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

# Add a log function for this script to be self-contained
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# Process command-line arguments
while getopts "b:e:r:f:h" opt; do
    case "$opt" in
        b)
            START_DATE="$OPTARG"
            ;;
        e)
            END_DATE="$OPTARG"
            ;;
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

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."
    exit 1
fi
log "✅ Dependencies met."

log "✍️ Preparing output file: $OUTPUT_FILE"
printf '"Volume ID","SizeGiB","State","Attached Instance ID","Disk Used %%","Avg Read Bytes","Avg Write Bytes","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    VOLUMES_DATA=$(aws ec2 describe-volumes --region "$region" --query 'Volumes[]' --output json)

    if [[ "$(echo "$VOLUMES_DATA" | jq 'length')" -gt 0 ]]; then
        echo "$VOLUMES_DATA" | jq -c '.[]' | while read -r volume; do
            ID=$(echo "$volume" | jq -r '.VolumeId')
            SIZE=$(echo "$volume" | jq -r '.Size')
            STATE=$(echo "$volume" | jq -r '.State')
            ATTACHMENT=$(echo "$volume" | jq -r '.Attachments[0].InstanceId // "Not Attached"')
            CREATION_TIME=$(echo "$volume" | jq -r '.CreateTime')

            # Get Disk Used % from CloudWatch Agent (if available)
            DISK_USED_PERCENT=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace CWAgent \
                --metric-name disk_used_percent \
                --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            # Get Disk Read Bytes from CloudWatch
            DISK_READ_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name DiskReadBytes \
                --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            # Get Disk Write Bytes from CloudWatch
            DISK_WRITE_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name DiskWriteBytes \
                --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            # Handle null or empty values
            DISK_USED_PERCENT=${DISK_USED_PERCENT:-"N/A"}
            if [ "$DISK_USED_PERCENT" = "null" ]; then
                DISK_USED_PERCENT="N/A"
            fi
            DISK_READ_BYTES=${DISK_READ_BYTES:-"N/A"}
            DISK_WRITE_BYTES=${DISK_WRITE_BYTES:-"N/A"}

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$ID" \
                "$SIZE" \
                "$STATE" \
                "$ATTACHMENT" \
                "$DISK_USED_PERCENT" \
                "$DISK_READ_BYTES" \
                "$DISK_WRITE_BYTES" \
                "$CREATION_TIME" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [EBS] No volumes found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

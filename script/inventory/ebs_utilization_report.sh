#!/bin/bash
# ebs_report.sh
# Generates a report on EBS volumes, showing attachment status, disk size, and utilization metrics.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ebs_utilization_report.csv"
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
printf '"Volume ID","SizeGiB","State","Attached Instance ID","Disk Used %%","Avg Volume Read Bytes","Avg Volume Write Bytes","Creation Time","Region"\n' > "$OUTPUT_FILE"

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

            # Only fetch CloudWatch metrics if volume is attached to an instance
            if [ "$ATTACHMENT" != "Not Attached" ]; then
                # Get Disk Used % from CloudWatch Agent (if available)
                DISK_USED_PERCENT=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace CWAgent \
                    --metric-name disk_used_percent \
                    --dimensions Name=InstanceId,Value="$ATTACHMENT" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                    --output text)

                # Get Volume Read Bytes from CloudWatch (per-volume metric)
                DISK_READ_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/EBS \
                    --metric-name VolumeReadBytes \
                    --dimensions Name=VolumeId,Value="$ID" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                    --output text)

                # Get Volume Write Bytes from CloudWatch (per-volume metric)
                DISK_WRITE_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/EBS \
                    --metric-name VolumeWriteBytes \
                    --dimensions Name=VolumeId,Value="$ID" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                    --output text)
            else
                DISK_USED_PERCENT="N/A"
                DISK_READ_BYTES="N/A"
                DISK_WRITE_BYTES="N/A"
            fi

            # Handle null or empty values
            DISK_USED_PERCENT=${DISK_USED_PERCENT:-"N/A"}
            if [ "$DISK_USED_PERCENT" = "null" ] || [ "$DISK_USED_PERCENT" = "None" ]; then
                DISK_USED_PERCENT="N/A"
            fi
            DISK_READ_BYTES=${DISK_READ_BYTES:-"N/A"}
            if [ "$DISK_READ_BYTES" = "null" ] || [ "$DISK_READ_BYTES" = "None" ]; then
                DISK_READ_BYTES="N/A"
            fi
            DISK_WRITE_BYTES=${DISK_WRITE_BYTES:-"N/A"}
            if [ "$DISK_WRITE_BYTES" = "null" ] || [ "$DISK_WRITE_BYTES" = "None" ]; then
                DISK_WRITE_BYTES="N/A"
            fi

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

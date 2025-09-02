#!/bin/bash
# ebs_volume_report.sh
# Script to generate a CSV report of EBS volumes, including attachment details and utility metrics.

# Exit immediately if a command fails
set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
TS=$(date +"%Y%m%d-%H%M%S")
FILENAME="ebs_report_${TS}.csv"
START_DATE=""
END_DATE=""
PERIOD=2592000 # Defaults to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Name of the output CSV file.
                   Default: ebs_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

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
            FILENAME="$OPTARG"
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

# Check for required arguments
if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# --- Utilities & Pre-Check ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

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
log "✍️ Preparing output file: $FILENAME"

# CSV Header
printf '"Volume ID","Size (GiB)","State","Attachment State","Attached Instance ID","Disk Used %%","Disk Read Bytes","Disk Write Bytes","Creation Time","Region"\n' > "$FILENAME"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    log "  [EBS] Fetching EBS volume data..."
    VOLUME_DATA=$(aws ec2 describe-volumes --region "$region" --query 'Volumes[]' --output json)

    if [[ "$(echo "$VOLUME_DATA" | jq 'length')" -gt 0 ]]; then
        log "  [EBS] Processing and writing to CSV..."
        while IFS= read -r volume; do
            VOL_ID=$(echo "$volume" | jq -r '.VolumeId')
            SIZE_GIB=$(echo "$volume" | jq -r '.Size')
            STATE=$(echo "$volume" | jq -r '.State')
            CREATE_TIME=$(echo "$volume" | jq -r '.CreateTime')
            
            # Getting attachment details
            ATTACHMENT=$(echo "$volume" | jq -r '.Attachments[0]')
            if [ "$ATTACHMENT" != "null" ]; then
                ATTACHMENT_STATE=$(echo "$ATTACHMENT" | jq -r '.State')
                INSTANCE_ID=$(echo "$ATTACHMENT" | jq -r '.InstanceId')
            else
                ATTACHMENT_STATE="unattached"
                INSTANCE_ID="N/A"
            fi
            
            # Fetching CloudWatch metrics (if available)
            DISK_USED_PERCENT="N/A"
            DISK_READ_BYTES="N/A"
            DISK_WRITE_BYTES="N/A"

            # Fetch disk usage metrics (if CloudWatch Agent is installed)
            if [ "$INSTANCE_ID" != "N/A" ]; then
                DISK_USED_PERCENT=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace CWAgent \
                    --metric-name disk_used_percent \
                    --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "Datapoints[0].Average" \
                    --output text)
            fi

            # Fetch disk I/O metrics
            DISK_READ_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EBS \
                --metric-name VolumeReadBytes \
                --dimensions Name=VolumeId,Value="$VOL_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text)

            DISK_WRITE_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EBS \
                --metric-name VolumeWriteBytes \
                --dimensions Name=VolumeId,Value="$VOL_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text)

            # Set N/A if metrics are not found
            if [ -z "$DISK_USED_PERCENT" ] || [ "$DISK_USED_PERCENT" = "null" ]; then
                DISK_USED_PERCENT="N/A"
            fi
            if [ -z "$DISK_READ_BYTES" ] || [ "$DISK_READ_BYTES" = "null" ]; then
                DISK_READ_BYTES="N/A"
            fi
            if [ -z "$DISK_WRITE_BYTES" ] || [ "$DISK_WRITE_BYTES" = "null" ]; then
                DISK_WRITE_BYTES="N/A"
            fi
            
            # Print data row to the CSV file
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$VOL_ID" \
                "$SIZE_GIB" \
                "$STATE" \
                "$ATTACHMENT_STATE" \
                "$INSTANCE_ID" \
                "$DISK_USED_PERCENT" \
                "$DISK_READ_BYTES" \
                "$DISK_WRITE_BYTES" \
                "$CREATE_TIME" \
                "$region" >> "$FILENAME"

        done < <(echo "$VOLUME_DATA" | jq -c '.[]')
    else
        log "  [EBS] No volumes found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Results saved to: $FILENAME"

#!/bin/bash
# sqs_report.sh
# Gathers an inventory report on all SQS queues.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sqs_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]
Options:
  -r <regions>     Comma-separated list of AWS regions. Default: ${REGIONS[*]}
  -h               Show this help message.
EOF
    exit 1
}

while getopts "r:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

# --- Main Script ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Queue Name","Queue URL","Queue ARN","Queue Type","Approximate Message Count","Approximate Messages Not Visible","Visibility Timeout","Retention Period","Created Timestamp","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # List all SQS queues with pagination support
    ALL_QUEUE_URLS=()
    NEXT_TOKEN=""

    while true; do
        if [[ -n "$NEXT_TOKEN" ]]; then
            RESPONSE=$(aws sqs list-queues --region "$region" --output json --next-token "$NEXT_TOKEN" 2>/dev/null || echo '{}')
        else
            RESPONSE=$(aws sqs list-queues --region "$region" --output json 2>/dev/null || echo '{}')
        fi

        # Extract queue URLs from this page
        PAGE_URLS=$(echo "$RESPONSE" | jq -r '.QueueUrls // [] | .[]' 2>/dev/null)
        while IFS= read -r url; do
            [[ -n "$url" ]] && ALL_QUEUE_URLS+=("$url")
        done <<< "$PAGE_URLS"

        # Check for next page
        NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.NextToken // empty' 2>/dev/null)
        if [[ -z "$NEXT_TOKEN" ]]; then
            break
        fi
    done

    QUEUE_COUNT=${#ALL_QUEUE_URLS[@]}

    if [[ "$QUEUE_COUNT" -eq 0 ]]; then
        log "  [SQS] No queues found."
    else
        log "  [SQS] Found $QUEUE_COUNT queues. Fetching attributes..."

        for queue_url in "${ALL_QUEUE_URLS[@]}"; do
            # Get queue attributes
            ATTRS=$(aws sqs get-queue-attributes --region "$region" \
                --queue-url "$queue_url" \
                --attribute-names All \
                --output json 2>/dev/null || echo '{"Attributes":{}}')

            # Extract queue name from URL (last path segment)
            QUEUE_NAME=$(echo "$queue_url" | awk -F'/' '{print $NF}')

            # Determine queue type
            if [[ "$QUEUE_NAME" == *.fifo ]]; then
                QUEUE_TYPE="FIFO"
            else
                QUEUE_TYPE="Standard"
            fi

            QUEUE_ARN=$(echo "$ATTRS" | jq -r '.Attributes.QueueArn // "N/A"')
            MSG_COUNT=$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessages // "N/A"')
            MSG_NOT_VISIBLE=$(echo "$ATTRS" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "N/A"')
            VISIBILITY_TIMEOUT=$(echo "$ATTRS" | jq -r '.Attributes.VisibilityTimeout // "N/A"')
            RETENTION_PERIOD=$(echo "$ATTRS" | jq -r '.Attributes.MessageRetentionPeriod // "N/A"')
            CREATED_TIMESTAMP=$(echo "$ATTRS" | jq -r '.Attributes.CreatedTimestamp // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$QUEUE_NAME" \
                "$queue_url" \
                "$QUEUE_ARN" \
                "$QUEUE_TYPE" \
                "$MSG_COUNT" \
                "$MSG_NOT_VISIBLE" \
                "$VISIBILITY_TIMEOUT" \
                "$RETENTION_PERIOD" \
                "$CREATED_TIMESTAMP" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

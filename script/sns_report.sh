#!/bin/bash
# sns_report.sh
# Gathers an inventory report on Amazon SNS topics and subscriptions.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sns_report.csv"

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

printf '"Topic Name","Topic ARN","Subscriptions Count","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # List all topics (--no-paginate to get all)
    TOPICS_DATA=$(aws sns list-topics --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Topics":[]}')

    TOPIC_COUNT=$(echo "$TOPICS_DATA" | jq '.Topics | length')

    if [[ "$TOPIC_COUNT" -eq 0 ]]; then
        log "  [SNS] No topics found."
    else
        log "  [SNS] Found $TOPIC_COUNT topics."
        echo "$TOPICS_DATA" | jq -r '.Topics[].TopicArn' | while read -r topic_arn; do
            # Extract topic name from ARN
            TOPIC_NAME=$(echo "$topic_arn" | awk -F: '{print $NF}')

            # Get subscription count for this topic
            SUB_COUNT=$(aws sns list-subscriptions-by-topic --region "$region" \
                --topic-arn "$topic_arn" \
                --query "length(Subscriptions)" --output text --no-paginate 2>/dev/null || echo "0")

            if [[ -z "$SUB_COUNT" || "$SUB_COUNT" == "None" ]]; then
                SUB_COUNT="0"
            fi

            printf '"%s","%s","%s","%s"\n' \
                "$TOPIC_NAME" \
                "$topic_arn" \
                "$SUB_COUNT" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

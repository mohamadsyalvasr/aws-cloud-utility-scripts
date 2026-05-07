#!/bin/bash
# kinesis_report.sh
# Gathers an inventory report on all Kinesis data streams.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/kinesis_report.csv"

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

printf '"Stream Name","Stream ARN","Stream Status","Stream Mode","Shard Count","Retention Period (hours)","Encryption Type","Creation Timestamp","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    STREAMS_DATA=$(aws kinesis list-streams --region "$region" --output json --no-paginate 2>/dev/null || echo '{"StreamNames":[]}')
    STREAM_COUNT=$(echo "$STREAMS_DATA" | jq '.StreamNames // [] | length')

    if [[ "$STREAM_COUNT" -eq 0 ]]; then
        log "  [Kinesis] No data streams found."
    else
        log "  [Kinesis] Found $STREAM_COUNT data streams. Fetching details..."

        echo "$STREAMS_DATA" | jq -r '.StreamNames // [] | .[]' | while read -r stream_name; do
            # Get stream summary details
            SUMMARY=$(aws kinesis describe-stream-summary --region "$region" \
                --stream-name "$stream_name" --output json 2>/dev/null || echo '{}')

            if [[ -z "$SUMMARY" || "$SUMMARY" == "{}" ]]; then
                log "    ⚠️ Could not describe stream: $stream_name"
                continue
            fi

            STREAM_ARN=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.StreamARN // "N/A"')
            STREAM_STATUS=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.StreamStatus // "N/A"')
            STREAM_MODE=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.StreamModeDetails.StreamMode // "N/A"')
            SHARD_COUNT=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.OpenShardCount // "N/A"')
            RETENTION=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.RetentionPeriodHours // "N/A"')
            ENCRYPTION=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.EncryptionType // "N/A"')
            CREATION_TS=$(echo "$SUMMARY" | jq -r '.StreamDescriptionSummary.StreamCreationTimestamp // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$stream_name" \
                "$STREAM_ARN" \
                "$STREAM_STATUS" \
                "$STREAM_MODE" \
                "$SHARD_COUNT" \
                "$RETENTION" \
                "$ENCRYPTION" \
                "$CREATION_TS" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

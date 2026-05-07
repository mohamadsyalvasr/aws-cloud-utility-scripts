#!/bin/bash
# cloudwatch_report.sh
# Gathers an inventory report on CloudWatch Alarms and Log Groups.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_ALARMS="${OUTPUT_DIR}/cloudwatch_alarms_report.csv"
OUTPUT_FILE_LOGS="${OUTPUT_DIR}/cloudwatch_log_groups_report.csv"

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

This script generates two CSV files:
  1. cloudwatch_alarms_report.csv     - CloudWatch Alarms
  2. cloudwatch_log_groups_report.csv - CloudWatch Log Groups
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
mkdir -p "$(dirname "$OUTPUT_FILE_ALARMS")"

# =========================================================================
# PART 1: CloudWatch Alarms
# =========================================================================
log "✍️ [Part 1] Generating CloudWatch Alarms report..."
printf '"Alarm Name","Namespace","Metric Name","State","Comparison","Threshold","Period (s)","Actions Enabled","Region"\n' > "$OUTPUT_FILE_ALARMS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Alarms)"

    ALARMS_DATA=$(aws cloudwatch describe-alarms --region "$region" --output json --no-paginate 2>/dev/null || echo '{"MetricAlarms":[]}')
    ALARM_COUNT=$(echo "$ALARMS_DATA" | jq '.MetricAlarms | length')

    if [[ "$ALARM_COUNT" -eq 0 ]]; then
        log "  [CloudWatch] No alarms found."
    else
        log "  [CloudWatch] Found $ALARM_COUNT alarms."
        echo "$ALARMS_DATA" | jq -c '.MetricAlarms[]' | while read -r alarm; do
            ALARM_NAME=$(echo "$alarm" | jq -r '.AlarmName // "N/A"')
            NAMESPACE=$(echo "$alarm" | jq -r '.Namespace // "N/A"')
            METRIC_NAME=$(echo "$alarm" | jq -r '.MetricName // "N/A"')
            STATE=$(echo "$alarm" | jq -r '.StateValue // "N/A"')
            COMPARISON=$(echo "$alarm" | jq -r '.ComparisonOperator // "N/A"')
            THRESHOLD=$(echo "$alarm" | jq -r '.Threshold // "N/A"')
            PERIOD=$(echo "$alarm" | jq -r '.Period // "N/A"')
            ACTIONS_ENABLED=$(echo "$alarm" | jq -r '.ActionsEnabled // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$ALARM_NAME" \
                "$NAMESPACE" \
                "$METRIC_NAME" \
                "$STATE" \
                "$COMPARISON" \
                "$THRESHOLD" \
                "$PERIOD" \
                "$ACTIONS_ENABLED" \
                "$region" >> "$OUTPUT_FILE_ALARMS"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done
log "✅ [Part 1] CloudWatch Alarms report saved to: $OUTPUT_FILE_ALARMS"

# =========================================================================
# PART 2: CloudWatch Log Groups
# =========================================================================
log "✍️ [Part 2] Generating CloudWatch Log Groups report..."
printf '"Log Group Name","Stored Bytes (GiB)","Retention (days)","KMS Key ID","Creation Time","Region"\n' > "$OUTPUT_FILE_LOGS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Log Groups)"

    LOGS_DATA=$(aws logs describe-log-groups --region "$region" --output json --no-paginate 2>/dev/null || echo '{"logGroups":[]}')
    LOG_COUNT=$(echo "$LOGS_DATA" | jq '.logGroups | length')

    if [[ "$LOG_COUNT" -eq 0 ]]; then
        log "  [CloudWatch Logs] No log groups found."
    else
        log "  [CloudWatch Logs] Found $LOG_COUNT log groups."
        echo "$LOGS_DATA" | jq -c '.logGroups[]' | while read -r loggroup; do
            LG_NAME=$(echo "$loggroup" | jq -r '.logGroupName // "N/A"')
            STORED_BYTES=$(echo "$loggroup" | jq -r '.storedBytes // 0')
            RETENTION=$(echo "$loggroup" | jq -r '.retentionInDays // "Never Expire"')
            KMS_KEY=$(echo "$loggroup" | jq -r '.kmsKeyId // "N/A"')
            CREATION_TIME=$(echo "$loggroup" | jq -r '.creationTime // "N/A"')

            # Convert stored bytes to GiB
            if [[ "$STORED_BYTES" != "0" && "$STORED_BYTES" != "null" ]]; then
                STORED_GIB=$(echo "scale=2; $STORED_BYTES / 1073741824" | bc)
            else
                STORED_GIB="0.00"
            fi

            # Convert creation time (epoch ms) to readable date
            if [[ "$CREATION_TIME" != "N/A" && "$CREATION_TIME" != "null" ]]; then
                CREATION_SEC=$(echo "$CREATION_TIME" | cut -c1-10)
                CREATION_DATE=$(date -u -d "@${CREATION_SEC}" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "$CREATION_TIME")
            else
                CREATION_DATE="N/A"
            fi

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$LG_NAME" \
                "$STORED_GIB" \
                "$RETENTION" \
                "$KMS_KEY" \
                "$CREATION_DATE" \
                "$region" >> "$OUTPUT_FILE_LOGS"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done
log "✅ [Part 2] CloudWatch Log Groups report saved to: $OUTPUT_FILE_LOGS"
log "✅ DONE. All CloudWatch reports generated."

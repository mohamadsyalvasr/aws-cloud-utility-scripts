#!/bin/bash
# eventbridge_report.sh
# Gathers an inventory report on all EventBridge rules across all event buses.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/eventbridge_report.csv"

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

printf '"Rule Name","Rule ARN","Event Bus Name","State","Schedule Expression","Target Count","Description","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    FOUND_RULES=0

    # List all event buses (default + custom)
    BUSES_DATA=$(aws events list-event-buses --region "$region" --output json --no-paginate 2>/dev/null || echo '{"EventBuses":[]}')
    BUS_NAMES=$(echo "$BUSES_DATA" | jq -r '.EventBuses // [] | .[].Name' 2>/dev/null)

    if [[ -z "$BUS_NAMES" ]]; then
        log "  [EventBridge] No event buses found."
        log "Region \033[1;33m$region\033[0m Complete."
        continue
    fi

    while IFS= read -r bus_name; do
        [[ -z "$bus_name" ]] && continue

        # List rules for this event bus
        RULES_DATA=$(aws events list-rules --region "$region" \
            --event-bus-name "$bus_name" --output json --no-paginate 2>/dev/null || echo '{"Rules":[]}')
        RULE_COUNT=$(echo "$RULES_DATA" | jq '.Rules // [] | length')

        if [[ "$RULE_COUNT" -eq 0 ]]; then
            continue
        fi

        FOUND_RULES=$((FOUND_RULES + RULE_COUNT))

        echo "$RULES_DATA" | jq -c '.Rules // [] | .[]' | while read -r rule; do
            RULE_NAME=$(echo "$rule" | jq -r '.Name // "N/A"')
            RULE_ARN=$(echo "$rule" | jq -r '.Arn // "N/A"')
            STATE=$(echo "$rule" | jq -r '.State // "N/A"')
            SCHEDULE=$(echo "$rule" | jq -r '.ScheduleExpression // "N/A"')
            DESCRIPTION=$(echo "$rule" | jq -r '.Description // "N/A"' | sed 's/"/""/g')

            # Count targets for this rule
            TARGETS_DATA=$(aws events list-targets-by-rule --region "$region" \
                --event-bus-name "$bus_name" --rule "$RULE_NAME" \
                --output json --no-paginate 2>/dev/null || echo '{"Targets":[]}')
            TARGET_COUNT=$(echo "$TARGETS_DATA" | jq '.Targets // [] | length')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$RULE_NAME" \
                "$RULE_ARN" \
                "$bus_name" \
                "$STATE" \
                "$SCHEDULE" \
                "$TARGET_COUNT" \
                "$DESCRIPTION" \
                "$region" >> "$OUTPUT_FILE"
        done
    done <<< "$BUS_NAMES"

    if [[ "$FOUND_RULES" -eq 0 ]]; then
        log "  [EventBridge] No rules found."
    else
        log "  [EventBridge] Found $FOUND_RULES rules across all buses."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

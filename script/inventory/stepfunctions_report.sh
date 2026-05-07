#!/bin/bash
# stepfunctions_report.sh
# Gathers an inventory report on all Step Functions state machines.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/stepfunctions_report.csv"

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

printf '"State Machine Name","State Machine ARN","Type","Status","Creation Date","Role ARN","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    SM_DATA=$(aws stepfunctions list-state-machines --region "$region" --output json --no-paginate 2>/dev/null || echo '{"stateMachines":[]}')
    SM_COUNT=$(echo "$SM_DATA" | jq '.stateMachines // [] | length')

    if [[ "$SM_COUNT" -eq 0 ]]; then
        log "  [Step Functions] No state machines found."
    else
        log "  [Step Functions] Found $SM_COUNT state machines."

        echo "$SM_DATA" | jq -c '.stateMachines // [] | .[]' | while read -r sm; do
            SM_NAME=$(echo "$sm" | jq -r '.name // "N/A"')
            SM_ARN=$(echo "$sm" | jq -r '.stateMachineArn // "N/A"')
            SM_TYPE=$(echo "$sm" | jq -r '.type // "N/A"')
            SM_STATUS="ACTIVE"
            CREATION_DATE=$(echo "$sm" | jq -r '.creationDate // "N/A"')
            ROLE_ARN=$(echo "$sm" | jq -r '.roleArn // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
                "$SM_NAME" \
                "$SM_ARN" \
                "$SM_TYPE" \
                "$SM_STATUS" \
                "$CREATION_DATE" \
                "$ROLE_ARN" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

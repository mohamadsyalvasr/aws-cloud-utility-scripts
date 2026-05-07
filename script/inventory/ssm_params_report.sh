#!/bin/bash
# ssm_params_report.sh
# Gathers an inventory report on all SSM Parameter Store parameters.
# NOTE: This script does NOT output parameter values to avoid exposing secrets.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ssm_params_report.csv"

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

printf '"Parameter Name","Parameter Type","Tier","Version","Last Modified Date","Data Type","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Use NextToken pagination for describe-parameters
    ALL_PARAMS="[]"
    NEXT_TOKEN=""

    while true; do
        if [[ -n "$NEXT_TOKEN" ]]; then
            RESPONSE=$(aws ssm describe-parameters --region "$region" --output json \
                --max-results 50 --next-token "$NEXT_TOKEN" 2>/dev/null || echo '{}')
        else
            RESPONSE=$(aws ssm describe-parameters --region "$region" --output json \
                --max-results 50 2>/dev/null || echo '{}')
        fi

        # Accumulate parameters
        PAGE_PARAMS=$(echo "$RESPONSE" | jq '.Parameters // []')
        ALL_PARAMS=$(echo "$ALL_PARAMS $PAGE_PARAMS" | jq -s '.[0] + .[1]')

        # Check for next page
        NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.NextToken // empty' 2>/dev/null)
        if [[ -z "$NEXT_TOKEN" ]]; then
            break
        fi
    done

    PARAM_COUNT=$(echo "$ALL_PARAMS" | jq 'length')

    if [[ "$PARAM_COUNT" -eq 0 ]]; then
        log "  [SSM Parameters] No parameters found."
    else
        log "  [SSM Parameters] Found $PARAM_COUNT parameters."

        echo "$ALL_PARAMS" | jq -c '.[]' | while read -r param; do
            PARAM_NAME=$(echo "$param" | jq -r '.Name // "N/A"')
            PARAM_TYPE=$(echo "$param" | jq -r '.Type // "N/A"')
            TIER=$(echo "$param" | jq -r '.Tier // "N/A"')
            VERSION=$(echo "$param" | jq -r '.Version // "N/A"')
            LAST_MODIFIED=$(echo "$param" | jq -r '.LastModifiedDate // "N/A"')
            DATA_TYPE=$(echo "$param" | jq -r '.DataType // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
                "$PARAM_NAME" \
                "$PARAM_TYPE" \
                "$TIER" \
                "$VERSION" \
                "$LAST_MODIFIED" \
                "$DATA_TYPE" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

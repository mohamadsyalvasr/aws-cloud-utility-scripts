#!/bin/bash
# lambda_report.sh
# Gathers a report on Lambda functions.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/lambda_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions]
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

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"FunctionName","Runtime","Handler","CodeSize","LastModified","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"
    
    LAMBDA_DATA=$(aws lambda list-functions --region "$region" --output json)
    
    if [[ "$(echo "$LAMBDA_DATA" | jq '.Functions | length')" -gt 0 ]]; then
        echo "$LAMBDA_DATA" | jq -r --arg r "$region" '.Functions[] | [.FunctionName, .Runtime, .Handler, .CodeSize, .LastModified, $r] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Lambda] No functions found."
    fi
     log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

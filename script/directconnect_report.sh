#!/bin/bash
# directconnect_report.sh
# Gathers an inventory report on AWS Direct Connect connections.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/directconnect_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions.
                   Default: ${REGIONS[*]}
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
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Connection Name","Connection ID","State","Bandwidth","Location","VLAN","Partner Name","LAG ID","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    CONN_DATA=$(aws directconnect describe-connections --region "$region" --output json 2>/dev/null || echo '{"connections":[]}')

    CONN_COUNT=$(echo "$CONN_DATA" | jq '.connections | length')

    if [[ "$CONN_COUNT" -eq 0 ]]; then
        log "  [Direct Connect] No connections found."
    else
        log "  [Direct Connect] Found $CONN_COUNT connections."
        echo "$CONN_DATA" | jq -c '.connections[]' | while read -r conn; do
            CONN_NAME=$(echo "$conn" | jq -r '.connectionName // "N/A"')
            CONN_ID=$(echo "$conn" | jq -r '.connectionId // "N/A"')
            STATE=$(echo "$conn" | jq -r '.connectionState // "N/A"')
            BANDWIDTH=$(echo "$conn" | jq -r '.bandwidth // "N/A"')
            LOCATION=$(echo "$conn" | jq -r '.location // "N/A"')
            VLAN=$(echo "$conn" | jq -r '.vlan // "N/A"')
            PARTNER=$(echo "$conn" | jq -r '.partnerName // "N/A"')
            LAG_ID=$(echo "$conn" | jq -r '.lagId // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$CONN_NAME" \
                "$CONN_ID" \
                "$STATE" \
                "$BANDWIDTH" \
                "$LOCATION" \
                "$VLAN" \
                "$PARTNER" \
                "$LAG_ID" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

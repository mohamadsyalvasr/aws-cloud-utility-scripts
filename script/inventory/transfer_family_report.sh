#!/bin/bash
# transfer_family_report.sh
# Gathers a report on AWS Transfer Family servers.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/transfer_family_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
EOF
    exit 1
}

while getopts "r:f:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Server ID","Protocol","State","Endpoint Type","Identity Provider","Domain","Region"\n' > "$OUTPUT_FILE"

TOTAL=${#REGIONS[@]}
COUNT=0

for region in "${REGIONS[@]}"; do
    COUNT=$((COUNT + 1))
    log "[$COUNT/$TOTAL] Processing Region: \033[1;33m$region\033[0m"

    SERVERS=$(aws transfer list-servers --region "$region" --output json 2>/dev/null || true)

    if [[ -n "$SERVERS" && "$(echo "$SERVERS" | jq '.Servers | length')" -gt 0 ]]; then
        echo "$SERVERS" | jq -r --arg r "$region" '.Servers[] | [
            .ServerId,
            (.Protocols // [] | join(",")),
            .State,
            .EndpointType,
            .IdentityProviderType,
            (.Domain // "S3"),
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  No Transfer Family servers found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

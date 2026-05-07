#!/bin/bash
# mq_report.sh
# Gathers a report on Amazon MQ brokers.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/mq_report.csv"

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

printf '"Broker Name","Broker ID","Engine Type","Engine Version","Instance Type","Deployment Mode","State","Region"\n' > "$OUTPUT_FILE"

TOTAL=${#REGIONS[@]}
COUNT=0

for region in "${REGIONS[@]}"; do
    COUNT=$((COUNT + 1))
    log "[$COUNT/$TOTAL] Processing Region: \033[1;33m$region\033[0m"

    BROKERS=$(aws mq list-brokers --region "$region" --output json 2>/dev/null || true)

    if [[ -n "$BROKERS" && "$(echo "$BROKERS" | jq '.BrokerSummaries | length')" -gt 0 ]]; then
        echo "$BROKERS" | jq -r --arg r "$region" '.BrokerSummaries[] | [
            .BrokerName,
            .BrokerId,
            .EngineType,
            .EngineVersion,
            .HostInstanceType,
            .DeploymentMode,
            .BrokerState,
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  No Amazon MQ brokers found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

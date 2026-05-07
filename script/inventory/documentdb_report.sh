#!/bin/bash
# documentdb_report.sh
# Gathers a report on Amazon DocumentDB clusters.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/documentdb_report.csv"

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

printf '"Cluster ID","Engine","Engine Version","Status","Instance Count","Storage Encrypted","Multi-AZ","Region"\n' > "$OUTPUT_FILE"

TOTAL=${#REGIONS[@]}
COUNT=0

for region in "${REGIONS[@]}"; do
    COUNT=$((COUNT + 1))
    log "[$COUNT/$TOTAL] Processing Region: \033[1;33m$region\033[0m"

    CLUSTERS=$(aws docdb describe-db-clusters --region "$region" --output json \
        --filter Name=engine,Values=docdb 2>/dev/null || true)

    if [[ -n "$CLUSTERS" && "$(echo "$CLUSTERS" | jq '.DBClusters | length')" -gt 0 ]]; then
        echo "$CLUSTERS" | jq -r --arg r "$region" '.DBClusters[] | [
            .DBClusterIdentifier,
            .Engine,
            .EngineVersion,
            .Status,
            (.DBClusterMembers | length | tostring),
            (.StorageEncrypted | tostring),
            (.MultiAZ | tostring),
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  No DocumentDB clusters found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

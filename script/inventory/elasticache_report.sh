#!/bin/bash
# elasticache_report.sh
# Gathers a report on all ElastiCache clusters and saves it to an output directory.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/elasticache_report.csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found. Please install it first."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found. Please install it first."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies

# Create the output directory if it doesn't exist
log "📁 Creating output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"
log "✅ Directory created."

log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Name","Node types","Type","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    CLUSTERS_DATA=$(aws elasticache describe-cache-clusters --region "$region" --output json)

    if [[ "$(echo "$CLUSTERS_DATA" | jq '.CacheClusters | length')" -gt 0 ]]; then
        echo "$CLUSTERS_DATA" | jq -c '.CacheClusters[]' | while read -r cluster; do
            NAME=$(echo "$cluster" | jq -r '.CacheClusterId')
            NODE_TYPE=$(echo "$cluster" | jq -r '.CacheNodeType')
            ENGINE=$(echo "$cluster" | jq -r '.Engine')

            printf '"%s","%s","%s","%s"\n' \
                "$NAME" \
                "$NODE_TYPE" \
                "$ENGINE" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [ElastiCache] No clusters found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

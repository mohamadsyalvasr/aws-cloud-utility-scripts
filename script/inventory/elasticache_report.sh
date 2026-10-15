#!/bin/bash
# elasticache_report.sh
# Gathers a report on all ElastiCache clusters and saves it to an output directory.

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/elasticache_report.csv"

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

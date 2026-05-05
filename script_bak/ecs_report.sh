#!/bin/bash
# ecs_report.sh
# Gathers a report on ECS Clusters.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ecs_report.csv"

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

printf '"ClusterName","Status","RunningTasksCount","PendingTasksCount","ActiveServicesCount","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"
    
    # List clusters (returns ARNs)
    CLUSTER_ARNS=$(aws ecs list-clusters --region "$region" --query "clusterArns[]" --output text)
    
    if [ -n "$CLUSTER_ARNS" ] && [ "$CLUSTER_ARNS" != "None" ]; then
        # Describe clusters (batch up to 100) - for simplicity, passing all ARNs (assuming < 100 for now)
        # IFS handled by shell expansion
        CLUSTERS_DATA=$(aws ecs describe-clusters --region "$region" --clusters $CLUSTER_ARNS --output json)
        
        echo "$CLUSTERS_DATA" | jq -r --arg r "$region" '.clusters[] | [.clusterName, .status, .runningTasksCount, .pendingTasksCount, .activeServicesCount, $r] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [ECS] No clusters found."
    fi
     log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

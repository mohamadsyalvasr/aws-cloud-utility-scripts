#!/bin/bash
# redshift_report.sh
# Gathers an inventory report on all Redshift clusters.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/redshift_report.csv"

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

printf '"Cluster Identifier","Node Type","Number of Nodes","Cluster Status","DB Name","Master Username","Endpoint Address","Endpoint Port","VPC ID","Encrypted","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    CLUSTER_DATA=$(aws redshift describe-clusters --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Clusters":[]}')
    CLUSTER_COUNT=$(echo "$CLUSTER_DATA" | jq '.Clusters // [] | length')

    if [[ "$CLUSTER_COUNT" -eq 0 ]]; then
        log "  [Redshift] No clusters found."
    else
        log "  [Redshift] Found $CLUSTER_COUNT clusters."

        echo "$CLUSTER_DATA" | jq -c '.Clusters // [] | .[]' | while read -r cluster; do
            CLUSTER_ID=$(echo "$cluster" | jq -r '.ClusterIdentifier // "N/A"')
            NODE_TYPE=$(echo "$cluster" | jq -r '.NodeType // "N/A"')
            NUM_NODES=$(echo "$cluster" | jq -r '.NumberOfNodes // "N/A"')
            STATUS=$(echo "$cluster" | jq -r '.ClusterStatus // "N/A"')
            DB_NAME=$(echo "$cluster" | jq -r '.DBName // "N/A"')
            MASTER_USER=$(echo "$cluster" | jq -r '.MasterUsername // "N/A"')
            ENDPOINT_ADDR=$(echo "$cluster" | jq -r '.Endpoint.Address // "N/A"')
            ENDPOINT_PORT=$(echo "$cluster" | jq -r '.Endpoint.Port // "N/A"')
            VPC_ID=$(echo "$cluster" | jq -r '.VpcId // "N/A"')
            ENCRYPTED=$(echo "$cluster" | jq -r '.Encrypted // "N/A"')
            CREATION_TIME=$(echo "$cluster" | jq -r '.ClusterCreateTime // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$CLUSTER_ID" \
                "$NODE_TYPE" \
                "$NUM_NODES" \
                "$STATUS" \
                "$DB_NAME" \
                "$MASTER_USER" \
                "$ENDPOINT_ADDR" \
                "$ENDPOINT_PORT" \
                "$VPC_ID" \
                "$ENCRYPTED" \
                "$CREATION_TIME" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

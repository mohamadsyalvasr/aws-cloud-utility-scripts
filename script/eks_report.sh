#!/bin/bash
# eks_report.sh
# Gathers a report on all EKS clusters and saves it to a dated output directory.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
# Create a dated output directory structure
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/eks_report_$(date +"%Y%m%d-%H%M%S").csv"

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

# Create the output directory with the full date path
log "📁 Creating output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"
log "✅ Directory created."

log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Name","Status","Kubernetes version","Support period","Upgrade policy","Date Created","Provider","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get a list of all EKS clusters in the region
    EKS_CLUSTERS=$(aws eks list-clusters --region "$region" --query 'clusters' --output json)
    
    if [[ "$(echo "$EKS_CLUSTERS" | jq 'length')" -gt 0 ]]; then
        echo "$EKS_CLUSTERS" | jq -c '.[]' | while read -r cluster_name; do
            # Remove surrounding quotes from the cluster name
            CLUSTER_NAME=$(echo "$cluster_name" | tr -d '"')
            
            # Get detailed information for each cluster
            CLUSTER_DETAILS=$(aws eks describe-cluster --region "$region" --name "$CLUSTER_NAME" --output json)

            NAME=$(echo "$CLUSTER_DETAILS" | jq -r '.cluster.name')
            STATUS=$(echo "$CLUSTER_DETAILS" | jq -r '.cluster.status')
            K8S_VERSION=$(echo "$CLUSTER_DETAILS" | jq -r '.cluster.version')
            CREATED_DATE=$(echo "$CLUSTER_DETAILS" | jq -r '.cluster.createdAt')
            
            # These fields are not directly available and require more complex logic
            # or manual lookups. Set them to N/A for this simple report.
            SUPPORT_PERIOD="N/A"
            UPGRADE_POLICY="N/A"
            PROVIDER="N/A"

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$STATUS" \
                "$K8S_VERSION" \
                "$SUPPORT_PERIOD" \
                "$UPGRADE_POLICY" \
                "$CREATED_DATE" \
                "$PROVIDER" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [EKS] No clusters found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# msk_report.sh
# Gathers a report on Amazon Managed Streaming for Apache Kafka (MSK) clusters.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/msk_report.csv"

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

printf '"Cluster Name","Cluster Type","State","Kafka Version","Broker Nodes","Instance Type","Region"\n' > "$OUTPUT_FILE"

TOTAL=${#REGIONS[@]}
COUNT=0

for region in "${REGIONS[@]}"; do
    COUNT=$((COUNT + 1))
    log "[$COUNT/$TOTAL] Processing Region: \033[1;33m$region\033[0m"

    CLUSTERS=$(aws kafka list-clusters-v2 --region "$region" --output json 2>/dev/null || true)

    if [[ -n "$CLUSTERS" && "$(echo "$CLUSTERS" | jq '.ClusterInfoList | length')" -gt 0 ]]; then
        CLUSTER_ARNS=$(echo "$CLUSTERS" | jq -r '.ClusterInfoList[].ClusterArn')
        while IFS= read -r cluster_arn; do
            [[ -z "$cluster_arn" ]] && continue
            DETAIL=$(aws kafka describe-cluster-v2 --cluster-arn "$cluster_arn" --region "$region" --output json 2>/dev/null || true)
            if [[ -n "$DETAIL" ]]; then
                echo "$DETAIL" | jq -r --arg r "$region" '.ClusterInfo | [
                    .ClusterName,
                    .ClusterType,
                    .State,
                    (if .ClusterType == "PROVISIONED" then .Provisioned.CurrentBrokerSoftwareInfo.KafkaVersion // "N/A" else .Serverless.VpcConfigs[0].SubnetIds[0] // "N/A" end),
                    (if .ClusterType == "PROVISIONED" then (.Provisioned.NumberOfBrokerNodes | tostring) else "N/A" end),
                    (if .ClusterType == "PROVISIONED" then .Provisioned.BrokerNodeGroupInfo.InstanceType // "N/A" else "Serverless" end),
                    $r
                ] | @csv' >> "$OUTPUT_FILE"
            fi
        done <<< "$CLUSTER_ARNS"
    else
        log "  No MSK clusters found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

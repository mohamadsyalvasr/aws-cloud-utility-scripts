#!/bin/bash
# natgateway_report.sh
# Gathers an inventory report on all NAT Gateways.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/natgateway_report.csv"

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

printf '"NAT Gateway ID","State","VPC ID","Subnet ID","Connectivity Type","Primary Public IP","Primary Private IP","Created Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    NAT_DATA=$(aws ec2 describe-nat-gateways --region "$region" --output json --no-paginate 2>/dev/null || echo '{"NatGateways":[]}')
    NAT_COUNT=$(echo "$NAT_DATA" | jq '.NatGateways // [] | length')

    if [[ "$NAT_COUNT" -eq 0 ]]; then
        log "  [NAT Gateway] No NAT Gateways found."
    else
        log "  [NAT Gateway] Found $NAT_COUNT NAT Gateways."

        echo "$NAT_DATA" | jq -c '.NatGateways // [] | .[]' | while read -r nat; do
            NAT_ID=$(echo "$nat" | jq -r '.NatGatewayId // "N/A"')
            STATE=$(echo "$nat" | jq -r '.State // "N/A"')
            VPC_ID=$(echo "$nat" | jq -r '.VpcId // "N/A"')
            SUBNET_ID=$(echo "$nat" | jq -r '.SubnetId // "N/A"')
            CONNECTIVITY=$(echo "$nat" | jq -r '.ConnectivityType // "N/A"')
            PUBLIC_IP=$(echo "$nat" | jq -r '.NatGatewayAddresses[0].PublicIp // "N/A"')
            PRIVATE_IP=$(echo "$nat" | jq -r '.NatGatewayAddresses[0].PrivateIp // "N/A"')
            CREATED_TIME=$(echo "$nat" | jq -r '.CreateTime // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAT_ID" \
                "$STATE" \
                "$VPC_ID" \
                "$SUBNET_ID" \
                "$CONNECTIVITY" \
                "$PUBLIC_IP" \
                "$PRIVATE_IP" \
                "$CREATED_TIME" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

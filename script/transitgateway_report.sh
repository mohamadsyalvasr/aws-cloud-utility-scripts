#!/bin/bash
# transitgateway_report.sh
# Gathers an inventory report on all Transit Gateways.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/transitgateway_report.csv"

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

printf '"Transit Gateway ID","State","Owner Account ID","ASN","Auto Accept Shared Attachments","Attachment Count","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    TGW_DATA=$(aws ec2 describe-transit-gateways --region "$region" --output json --no-paginate 2>/dev/null || echo '{"TransitGateways":[]}')
    TGW_COUNT=$(echo "$TGW_DATA" | jq '.TransitGateways // [] | length')

    if [[ "$TGW_COUNT" -eq 0 ]]; then
        log "  [Transit Gateway] No Transit Gateways found."
    else
        log "  [Transit Gateway] Found $TGW_COUNT Transit Gateways."

        echo "$TGW_DATA" | jq -c '.TransitGateways // [] | .[]' | while read -r tgw; do
            TGW_ID=$(echo "$tgw" | jq -r '.TransitGatewayId // "N/A"')
            STATE=$(echo "$tgw" | jq -r '.State // "N/A"')
            OWNER_ID=$(echo "$tgw" | jq -r '.OwnerId // "N/A"')
            ASN=$(echo "$tgw" | jq -r '.Options.AmazonSideAsn // "N/A"')
            AUTO_ACCEPT=$(echo "$tgw" | jq -r '.Options.AutoAcceptSharedAttachments // "N/A"')
            CREATION_TIME=$(echo "$tgw" | jq -r '.CreationTime // "N/A"')

            # Count attachments for this Transit Gateway
            ATTACH_DATA=$(aws ec2 describe-transit-gateway-attachments --region "$region" \
                --filters "Name=transit-gateway-id,Values=$TGW_ID" \
                --output json --no-paginate 2>/dev/null || echo '{"TransitGatewayAttachments":[]}')
            ATTACH_COUNT=$(echo "$ATTACH_DATA" | jq '.TransitGatewayAttachments // [] | length')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$TGW_ID" \
                "$STATE" \
                "$OWNER_ID" \
                "$ASN" \
                "$AUTO_ACCEPT" \
                "$ATTACH_COUNT" \
                "$CREATION_TIME" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

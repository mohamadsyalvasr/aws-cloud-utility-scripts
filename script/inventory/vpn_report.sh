#!/bin/bash
# vpn_report.sh
# Gathers a report on Site-to-Site VPN Connections.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/vpn_report.csv"

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

printf '"VpnConnectionId","State","CustomerGatewayId","VpnGatewayId","Type","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"
    
    VPN_DATA=$(aws ec2 describe-vpn-connections --region "$region" --output json)
    
    if [[ "$(echo "$VPN_DATA" | jq '.VpnConnections | length')" -gt 0 ]]; then
        echo "$VPN_DATA" | jq -r --arg r "$region" '.VpnConnections[] | [.VpnConnectionId, .State, .CustomerGatewayId, .VpnGatewayId, .Type, $r] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [VPN] No VPN connections found."
    fi
     log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# elb_report.sh
# Gathers a report on all Elastic Load Balancers (ELB).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
# Output path is handled by main_report_runner.sh
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_FILE="output/${YEAR}/${MONTH}/${DAY}/elb_report_$(date +"%Y%m%d-%H%M%S").csv"

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

log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Name","State","Type","Scheme","IP address type","VPC ID","Security groups","Date created","DNS name"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: [1;33m$region[0m"

    # Get a list of all ELBs in the region
    ELB_DATA=$(aws elbv2 describe-load-balancers --region "$region" --output json)
    
    # Use the `// []` trick to provide an empty array if `LoadBalancers` is null
    if [[ "$(echo "$ELB_DATA" | jq '.LoadBalancers // [] | length')" -gt 0 ]]; then
        echo "$ELB_DATA" | jq -c '.LoadBalancers[]' | while read -r elb_info; do
            NAME=$(echo "$elb_info" | jq -r '.LoadBalancerName')
            STATE=$(echo "$elb_info" | jq -r '.State.Code')
            TYPE=$(echo "$elb_info" | jq -r '.Type')
            SCHEME=$(echo "$elb_info" | jq -r '.Scheme')
            IP_ADDRESS_TYPE=$(echo "$elb_info" | jq -r '.IpAddressType')
            VPC_ID=$(echo "$elb_info" | jq -r '.VpcId')
            SECURITY_GROUPS=$(echo "$elb_info" | jq -r '[.SecurityGroups[]] | join(", ")')
            CREATED_DATE=$(echo "$elb_info" | jq -r '.CreatedTime')
            DNS_NAME=$(echo "$elb_info" | jq -r '.DNSName')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$STATE" \
                "$TYPE" \
                "$SCHEME" \
                "$IP_ADDRESS_TYPE" \
                "$VPC_ID" \
                "$SECURITY_GROUPS" \
                "$CREATED_DATE" \
                "$DNS_NAME" >> "$OUTPUT_FILE"
        done
    else
        log "  [ELB] No load balancers found."
    fi

    log "Region [1;33m$region[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

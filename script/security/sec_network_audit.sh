#!/bin/bash
# sec_network_audit.sh
# Network Security Audit - Always runs manually (not covered by Trusted Advisor).
# Checks: VPC flow logs, default VPC usage, subnets with auto-assign public IP.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_network_audit.csv"
REGIONS=("ap-southeast-1")

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
Options:
  -r <regions>   Comma-separated list of AWS regions to scan.
  -f <filename>  Custom output filename.
  -h             Show this help message.
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

# --- Setup ---
mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Main ---
log "📊 Network Security Audit"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

FINDING_COUNT=0
REGION_COUNT=${#REGIONS[@]}
REGION_IDX=0

for region in "${REGIONS[@]}"; do
    REGION_IDX=$((REGION_IDX + 1))
    log "  [$REGION_IDX/$REGION_COUNT] Processing region: \033[1;33m$region\033[0m"

    # =========================================================================
    # 1. Check VPCs without flow logs
    # =========================================================================
    log "    [1/3] Checking VPC flow logs..."
    set +e
    VPCS=$(aws ec2 describe-vpcs --region "$region" --query 'Vpcs[*].[VpcId,IsDefault]' --output json 2>/dev/null)
    VPC_EXIT=$?
    set -e

    if [[ $VPC_EXIT -ne 0 ]]; then
        log "      ⚠️ Could not describe VPCs in $region. Skipping."
        continue
    fi

    VPC_COUNT=$(echo "$VPCS" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$VPC_COUNT" -gt 0 ]]; then
        for i in $(seq 0 $((VPC_COUNT - 1))); do
            VPC_ID=$(echo "$VPCS" | jq -r ".[$i][0]")

            # Check if VPC has flow logs
            set +e
            FLOW_LOGS=$(aws ec2 describe-flow-logs --region "$region" \
                --filter "Name=resource-id,Values=$VPC_ID" \
                --query 'FlowLogs' --output json 2>/dev/null)
            set -e

            FL_COUNT=$(echo "$FLOW_LOGS" | jq 'length' 2>/dev/null || echo "0")
            if [[ "$FL_COUNT" -eq 0 ]]; then
                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "VPC has no flow logs" \
                    "$VPC_ID" \
                    "VPC $VPC_ID in $region does not have flow logs enabled" \
                    "Medium" \
                    "Enable VPC Flow Logs for network traffic visibility" \
                    "$region" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
            fi
        done
    fi

    # =========================================================================
    # 2. Check default VPC usage
    # =========================================================================
    log "    [2/3] Checking default VPC..."
    set +e
    DEFAULT_VPCS=$(aws ec2 describe-vpcs --region "$region" \
        --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[*].VpcId' --output json 2>/dev/null)
    set -e

    DEFAULT_COUNT=$(echo "$DEFAULT_VPCS" | jq 'length' 2>/dev/null || echo "0")
    if [[ "$DEFAULT_COUNT" -gt 0 ]]; then
        DEFAULT_VPC_ID=$(echo "$DEFAULT_VPCS" | jq -r '.[0]')
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Default VPC in use" \
            "$DEFAULT_VPC_ID" \
            "Default VPC $DEFAULT_VPC_ID exists in region $region" \
            "Low" \
            "Use custom VPCs with proper network segmentation" \
            "$region" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    # =========================================================================
    # 3. Check subnets with auto-assign public IP
    # =========================================================================
    log "    [3/3] Checking subnets with auto-assign public IP..."
    set +e
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets --region "$region" \
        --filters "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[*].[SubnetId,VpcId,CidrBlock,AvailabilityZone]' --output json 2>/dev/null)
    SUBNET_EXIT=$?
    set -e

    if [[ $SUBNET_EXIT -ne 0 ]]; then
        log "      ⚠️ Could not describe subnets in $region. Skipping."
    else
        SUBNET_COUNT=$(echo "$PUBLIC_SUBNETS" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$SUBNET_COUNT" -gt 0 ]]; then
            log "      Found $SUBNET_COUNT subnet(s) with auto-assign public IP"
            for i in $(seq 0 $((SUBNET_COUNT - 1))); do
                SUBNET_ID=$(echo "$PUBLIC_SUBNETS" | jq -r ".[$i][0]")
                SUBNET_VPC=$(echo "$PUBLIC_SUBNETS" | jq -r ".[$i][1]")
                SUBNET_CIDR=$(echo "$PUBLIC_SUBNETS" | jq -r ".[$i][2]")
                SUBNET_AZ=$(echo "$PUBLIC_SUBNETS" | jq -r ".[$i][3]")

                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "Subnet auto-assigns public IP" \
                    "$SUBNET_ID" \
                    "Subnet $SUBNET_ID ($SUBNET_CIDR) in VPC $SUBNET_VPC ($SUBNET_AZ) auto-assigns public IPs" \
                    "Medium" \
                    "Disable MapPublicIpOnLaunch unless explicitly required" \
                    "$region" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
            done
        else
            log "      ✅ No subnets with auto-assign public IP"
        fi
    fi

    log "    Region $region complete."
done

log "✅ DONE. Network security audit complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

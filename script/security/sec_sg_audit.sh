#!/bin/bash
# sec_sg_audit.sh
# Security Group Audit - Manual fallback for SG security checks.
# Checks: SSH/RDP open to world, all traffic open, any port open, unrestricted egress, unused SGs.
# Skips if Trusted Advisor already covered SG category.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_sg_audit.csv"
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

# --- Coverage Check ---
COVERAGE_FILE="${OUTPUT_DIR}/.ta_coverage"
MY_CATEGORY="SG"

if [[ -f "$COVERAGE_FILE" ]] && grep -q "^${MY_CATEGORY}$" "$COVERAGE_FILE"; then
    log "⏭️ Skipping ${MY_CATEGORY} audit — covered by Trusted Advisor"
    printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"
    exit 0
fi

# --- Main ---
log "📊 Security Group Audit (Manual Fallback)"
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
    # 1. Check inbound rules for overly permissive access
    # =========================================================================
    set +e
    SG_DATA=$(aws ec2 describe-security-groups --region "$region" --output json 2>/dev/null)
    SG_EXIT=$?
    set -e

    if [[ $SG_EXIT -ne 0 ]] || [[ -z "$SG_DATA" ]]; then
        log "    ⚠️ Could not describe security groups in $region. Skipping."
        continue
    fi

    SG_COUNT=$(echo "$SG_DATA" | jq '.SecurityGroups | length')
    log "    Found $SG_COUNT security group(s)"

    # Get list of SGs attached to network interfaces for unused check
    set +e
    ENI_SGS=$(aws ec2 describe-network-interfaces --region "$region" \
        --query 'NetworkInterfaces[*].Groups[*].GroupId' --output json 2>/dev/null | jq -r '.[][] // empty' | sort -u)
    set -e

    echo "$SG_DATA" | jq -c '.SecurityGroups[]' | while read -r sg; do
        SG_ID=$(echo "$sg" | jq -r '.GroupId')
        SG_NAME=$(echo "$sg" | jq -r '.GroupName')
        VPC_ID=$(echo "$sg" | jq -r '.VpcId // "N/A"')

        # Check inbound rules
        echo "$sg" | jq -c '.IpPermissions[]?' | while read -r rule; do
            PROTOCOL=$(echo "$rule" | jq -r '.IpProtocol')
            FROM_PORT=$(echo "$rule" | jq -r '.FromPort // -1')
            TO_PORT=$(echo "$rule" | jq -r '.ToPort // -1')

            # Check IPv4 CIDRs
            echo "$rule" | jq -r '.IpRanges[]?.CidrIp // empty' | while read -r cidr; do
                if [[ "$cidr" == "0.0.0.0/0" ]]; then
                    if [[ "$PROTOCOL" == "-1" ]]; then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "All traffic open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows all inbound traffic from 0.0.0.0/0" \
                            "Critical" \
                            "Restrict inbound rules to specific IPs and ports" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    elif [[ "$FROM_PORT" -eq 22 ]] || ([[ "$FROM_PORT" -le 22 ]] && [[ "$TO_PORT" -ge 22 ]]); then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "SSH open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows SSH (port 22) from 0.0.0.0/0" \
                            "Critical" \
                            "Restrict SSH access to specific IP ranges" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    elif [[ "$FROM_PORT" -eq 3389 ]] || ([[ "$FROM_PORT" -le 3389 ]] && [[ "$TO_PORT" -ge 3389 ]]); then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "RDP open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows RDP (port 3389) from 0.0.0.0/0" \
                            "Critical" \
                            "Restrict RDP access to specific IP ranges" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    else
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "Port $FROM_PORT open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows port $FROM_PORT-$TO_PORT from 0.0.0.0/0" \
                            "High" \
                            "Restrict access to specific IP ranges" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    fi
                fi
            done

            # Check IPv6 CIDRs
            echo "$rule" | jq -r '.Ipv6Ranges[]?.CidrIpv6 // empty' | while read -r cidr6; do
                if [[ "$cidr6" == "::/0" ]]; then
                    if [[ "$PROTOCOL" == "-1" ]]; then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "All traffic open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows all inbound traffic from ::/0" \
                            "Critical" \
                            "Restrict inbound rules to specific IPs and ports" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    elif [[ "$FROM_PORT" -eq 22 ]] || ([[ "$FROM_PORT" -le 22 ]] && [[ "$TO_PORT" -ge 22 ]]); then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "SSH open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows SSH (port 22) from ::/0" \
                            "Critical" \
                            "Restrict SSH access to specific IP ranges" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    elif [[ "$FROM_PORT" -eq 3389 ]] || ([[ "$FROM_PORT" -le 3389 ]] && [[ "$TO_PORT" -ge 3389 ]]); then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "RDP open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows RDP (port 3389) from ::/0" \
                            "Critical" \
                            "Restrict RDP access to specific IP ranges" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    else
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "Port $FROM_PORT open to world" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows port $FROM_PORT-$TO_PORT from ::/0" \
                            "High" \
                            "Restrict access to specific IP ranges" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    fi
                fi
            done
        done

        # Check egress rules for unrestricted outbound
        echo "$sg" | jq -c '.IpPermissionsEgress[]?' | while read -r egress_rule; do
            EG_PROTOCOL=$(echo "$egress_rule" | jq -r '.IpProtocol')
            if [[ "$EG_PROTOCOL" == "-1" ]]; then
                echo "$egress_rule" | jq -r '.IpRanges[]?.CidrIp // empty' | while read -r cidr; do
                    if [[ "$cidr" == "0.0.0.0/0" ]]; then
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "Unrestricted egress" \
                            "$SG_ID" \
                            "SG $SG_NAME ($VPC_ID) allows all outbound traffic to 0.0.0.0/0" \
                            "Low" \
                            "Consider restricting egress to required destinations" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    fi
                done
            fi
        done

        # Check if SG is unused (not attached to any ENI)
        if [[ "$SG_NAME" != "default" ]] && ! echo "$ENI_SGS" | grep -q "^${SG_ID}$"; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "Unused security group" \
                "$SG_ID" \
                "SG $SG_NAME ($VPC_ID) is not associated with any network interface" \
                "Low" \
                "Delete unused security groups to reduce attack surface" \
                "$region" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        fi
    done

    log "    Region $region complete."
done

log "✅ DONE. Security Group audit complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

#!/bin/bash
# vpc_report.sh
# Gathers a summary report of VPC-related services and their quantities (per region).

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/vpc_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: vpc_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Helper: write one CSV row ---
write_row() {
    printf '"%s","%s","%s"\n' "$1" "$2" "$3" >> "$OUTPUT_FILE"
}

# --- Main Script Logic ---
main() {
    check_dependencies
    
    while getopts "r:f:h" opt; do
        case "$opt" in
            r)
                IFS=',' read -r -a REGIONS <<< "$OPTARG"
                ;;
            f)
                OUTPUT_FILE="$OPTARG"
                ;;
            h)
                usage
                ;;
            *)
                usage
                ;;
        esac
    done
    shift $((OPTIND-1))

    log "✍️ Preparing output file: $OUTPUT_FILE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    printf '"Services","Qty","Region"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local vpc_count=$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text)
        write_row "VPC" "$vpc_count" "$region"

        local subnet_count=$(aws ec2 describe-subnets --region "$region" --query 'length(Subnets)' --output text)
        write_row "Subnet" "$subnet_count" "$region"

        local igw_count=$(aws ec2 describe-internet-gateways --region "$region" --query 'length(InternetGateways)' --output text)
        write_row "Internet Gateway" "$igw_count" "$region"

        local nat_gw_count=$(aws ec2 describe-nat-gateways --region "$region" --query 'length(NatGateways)' --output text)
        write_row "NAT Gateway" "$nat_gw_count" "$region"

        local route_table_count=$(aws ec2 describe-route-tables --region "$region" --query 'length(RouteTables)' --output text)
        write_row "Route Table" "$route_table_count" "$region"

        local nacl_count=$(aws ec2 describe-network-acls --region "$region" --query 'length(NetworkAcls)' --output text)
        write_row "Network ACL" "$nacl_count" "$region"

        local security_group_count=$(aws ec2 describe-security-groups --region "$region" --query 'length(SecurityGroups)' --output text)
        write_row "Security Group" "$security_group_count" "$region"

        local eip_total=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text)
        local eip_used=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses[?AssociationId!=null])' --output text)
        local eip_idle=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses[?AssociationId==null])' --output text)
        write_row "Elastic IP (Total)" "$eip_total" "$region"
        write_row "Elastic IP (Used)" "$eip_used" "$region"
        write_row "Elastic IP (Idle)" "$eip_idle" "$region"

        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
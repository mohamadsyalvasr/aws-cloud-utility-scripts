#!/bin/bash
# vpc_report.sh
# Gathers a summary report of VPC-related services and their quantities (per region).

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
# Default values, can be overridden by command-line arguments
REGIONS=("ap-southeast-1" "ap-southeast-3")
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/vpc_report.csv"

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

# --- Process command-line arguments ---
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

# --- Helper: write one CSV row ---
write_row() {
  # args: service qty region
  printf '"%s","%s","%s"\n' "$1" "$2" "$3" >> "$OUTPUT_FILE"
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

# CSV header
printf '"Services","Qty","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
  log "Processing Region: \033[1;33m$region\033[0m"

  # VPCs
  VPC_COUNT=$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text)
  write_row "VPC" "$VPC_COUNT" "$region"

  # Subnets
  SUBNET_COUNT=$(aws ec2 describe-subnets --region "$region" --query 'length(Subnets)' --output text)
  write_row "Subnet" "$SUBNET_COUNT" "$region"

  # Internet Gateways
  IGW_COUNT=$(aws ec2 describe-internet-gateways --region "$region" --query 'length(InternetGateways)' --output text)
  write_row "Internet Gateway" "$IGW_COUNT" "$region"

  # NAT Gateways
  NAT_GW_COUNT=$(aws ec2 describe-nat-gateways --region "$region" --query 'length(NatGateways)' --output text)
  write_row "NAT Gateway" "$NAT_GW_COUNT" "$region"

  # Route Tables
  ROUTE_TABLE_COUNT=$(aws ec2 describe-route-tables --region "$region" --query 'length(RouteTables)' --output text)
  write_row "Route Table" "$ROUTE_TABLE_COUNT" "$region"

  # Network ACLs
  NACL_COUNT=$(aws ec2 describe-network-acls --region "$region" --query 'length(NetworkAcls)' --output text)
  write_row "Network ACL" "$NACL_COUNT" "$region"

  # Security Groups
  SECURITY_GROUP_COUNT=$(aws ec2 describe-security-groups --region "$region" --query 'length(SecurityGroups)' --output text)
  write_row "Security Group" "$SECURITY_GROUP_COUNT" "$region"

  # Elastic IPs (Total / Used / Idle)
  EIP_TOTAL=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses)' --output text)
  EIP_USED=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses[?AssociationId!=null])' --output text)
  EIP_IDLE=$(aws ec2 describe-addresses --region "$region" --query 'length(Addresses[?AssociationId==null])' --output text)
  write_row "Elastic IP (Total)" "$EIP_TOTAL" "$region"
  write_row "Elastic IP (Used)"  "$EIP_USED"  "$region"
  write_row "Elastic IP (Idle)"  "$EIP_IDLE"  "$region"

  log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

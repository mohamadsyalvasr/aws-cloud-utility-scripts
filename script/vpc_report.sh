#!/bin/bash
# vpc_report.sh
# Gathers a summary report of VPC-related services and their quantities (per region).

set -euo pipefail

# --- Configuration ---
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

# --- Helper: write one CSV row ---
write_row() {
  # args: service qty region
  printf '"%s","%s","%s"\n' "$1" "$2" "$3" >> "$OUTPUT_FILE"
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$OUTPUT_DIR"

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

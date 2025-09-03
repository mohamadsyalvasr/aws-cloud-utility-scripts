#!/bin/bash
# vpc_report.sh
# Gathers a summary report of VPC-related services and their quantities.

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

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Services","Qty","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Count VPCs
    VPC_COUNT=$(aws ec2 describe-vpcs --region "$region" --query 'Vpcs | length')
    printf '"VPC","%s","%s"\n' "$VPC_COUNT" "$region" >> "$OUTPUT_FILE"

    # Count Subnets
    SUBNET_COUNT=$(aws ec2 describe-subnets --region "$region" --query 'Subnets | length')
    printf '"Subnet","%s","%s"\n' "$SUBNET_COUNT" "$region" >> "$OUTPUT_FILE"

    # Count Internet Gateways
    IGW_COUNT=$(aws ec2 describe-internet-gateways --region "$region" --query 'InternetGateways | length')
    printf '"Internet Gateway","%s","%s"\n' "$IGW_COUNT" "$region" >> "$OUTPUT_FILE"
    
    # Count NAT Gateways
    NAT_GW_COUNT=$(aws ec2 describe-nat-gateways --region "$region" --query 'NatGateways | length')
    printf '"NAT Gateway","%s","%s"\n' "$NAT_GW_COUNT" "$region" >> "$OUTPUT_FILE"

    # Count Route Tables
    ROUTE_TABLE_COUNT=$(aws ec2 describe-route-tables --region "$region" --query 'RouteTables | length')
    printf '"Route Table","%s","%s"\n' "$ROUTE_TABLE_COUNT" "$region" >> "$OUTPUT_FILE"
    
    # Count Network ACLs
    NACL_COUNT=$(aws ec2 describe-network-acls --region "$region" --query 'NetworkAcls | length')
    printf '"Network ACL","%s","%s"\n' "$NACL_COUNT" "$region" >> "$OUTPUT_FILE"
    
    # Count Security Groups
    SECURITY_GROUP_COUNT=$(aws ec2 describe-security-groups --region "$region" --query 'SecurityGroups | length')
    printf '"Security Group","%s","%s"\n' "$SECURITY_GROUP_COUNT" "$region" >> "$OUTPUT_FILE"

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

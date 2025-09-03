#!/bin/bash
# elb_report.sh
# Gathers a report on all Elastic Load Balancers (ELBv2: ALB/NLB/GWLB) across regions into a CSV.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")

YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_FILE="output/${YEAR}/${MONTH}/${DAY}/elb_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging ---
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

# --- Prepare output ---
prepare_output() {
  log "✍️ Preparing output file: $OUTPUT_FILE"
  mkdir -p "$(dirname "$OUTPUT_FILE")"
  # CSV header
  printf '"Name","State","Type","Scheme","IP address type","VPC ID","Security groups","Date created","DNS name"\n' > "$OUTPUT_FILE"
}

# --- Export one region ---
export_region() {
  local region="$1"
  log "Processing Region: \033[1;33m$region\033[0m"

  # Fetch ELBv2 data (AWS CLI auto-paginates; bump page-size just in case)
  local elb_data
  if ! elb_data=$(aws elbv2 describe-load-balancers --region "$region" --output json --page-size 400); then
    log "  ❌ Failed to describe load balancers in $region"
    return 1
  fi

  # If empty, log and continue
  if [[ "$(echo "$elb_data" | jq '.LoadBalancers | length // 0')" -eq 0 ]]; then
    log "  [ELB] No load balancers found."
  else
    # Build CSV rows via jq (null-safe + auto-escape with @csv)
    echo "$elb_data" | jq -r '
      .LoadBalancers[]
      | [
          (.LoadBalancerName // ""),
          (.State.Code // ""),
          (.Type // ""),
          (.Scheme // ""),
          (.IpAddressType // ""),
          (.VpcId // ""),
          ((.SecurityGroups // []) | join(", ")),
          (.CreatedTime // ""),
          (.DNSName // "")
        ]
      | @csv
    ' >> "$OUTPUT_FILE"
  fi

  log "Region \033[1;33m$region\033[0m Complete."
}

# --- Main ---
check_dependencies
prepare_output

for region in "${REGIONS[@]}"; do
  export_region "$region"
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

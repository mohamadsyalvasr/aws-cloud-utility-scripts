#!/bin/bash
# elb_report.sh
# Gathers a report on all Elastic Load Balancers (ELBv2: ALB/NLB/GWLB) across regions into a CSV.

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
# Default values, can be overridden by command-line arguments
REGIONS=("ap-southeast-1" "ap-southeast-3")
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/elb_report.csv"

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: elb_report_<timestamp>.csv
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

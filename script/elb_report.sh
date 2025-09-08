#!/bin/bash
# elb_report.sh
# Gathers a report on all Elastic Load Balancers (ELBv2: ALB/NLB/GWLB) across regions into a CSV.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/elb_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging ---
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
                   Default: elb_report_<timestamp>.csv
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

# --- Export one region ---
export_region() {
    local region="$1"
    log "Processing Region: \033[1;33m$region\033[0m"

    local elb_data
    if ! elb_data=$(aws elbv2 describe-load-balancers --region "$region" --output json); then
        log "  ❌ Failed to describe load balancers in $region"
        return 1
    fi

    if [[ "$(echo "$elb_data" | jq '.LoadBalancers | length // 0')" -eq 0 ]]; then
        log "  [ELB] No load balancers found."
    else
        echo "$elb_data" | jq -r '
          .LoadBalancers[]
          | [
              (.LoadBalancerName // "N/A"),
              (.State.Code // "N/A"),
              (.Type // "N/A"),
              (.Scheme // "N/A"),
              (.IpAddressType // "N/A"),
              (.VpcId // "N/A"),
              ((.SecurityGroups // []) | join(", ")),
              (.CreatedTime // "N/A"),
              (.DNSName // "N/A")
            ]
          | @csv
        ' >> "$OUTPUT_FILE"
    fi

    log "Region \033[1;33m$region\033[0m Complete."
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

    printf '"Name","State","Type","Scheme","IP address type","VPC ID","Security groups","Date created","DNS name","Region"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        export_region "$region"
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
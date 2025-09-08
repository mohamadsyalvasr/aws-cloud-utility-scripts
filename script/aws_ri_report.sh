#!/bin/bash
# aws_ri_report.sh
# A standalone script to generate a detailed report on AWS Reserved Instances (RI).

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_ri_report_$(date +"%Y%m%d-%H%M%S").csv"

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
  -f <filename>    Name of the output CSV file.
                   Default: aws_ri_report_<timestamp>.csv
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

    # Create CSV header with all the new columns
    printf '"ID","Instance Type","Scope","Availability Zone","Instance Count","Start","Expires","Term","Payment Option","Offering Class","Hourly Charges","Platform","State"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local ri_data=$(aws ec2 describe-reserved-instances --region "$region" --query "ReservedInstances[]" --output json)
        if [[ "$(echo "$ri_data" | jq 'length')" -eq 0 ]]; then
            log "  [RI] No Reserved Instances found."
        else
            echo "$ri_data" | jq -c '.[]' | while read -r ri_instance; do
                local id=$(echo "$ri_instance" | jq -r '.ReservedInstancesId')
                local instance_type=$(echo "$ri_instance" | jq -r '.InstanceType')
                local scope=$(echo "$ri_instance" | jq -r '.Scope')
                local availability_zone=$(echo "$ri_instance" | jq -r '.AvailabilityZone // "N/A"')
                local instance_count=$(echo "$ri_instance" | jq -r '.InstanceCount')
                local start=$(echo "$ri_instance" | jq -r '.Start')
                local expires=$(echo "$ri_instance" | jq -r '.End')
                local term=$(echo "$ri_instance" | jq -r '.Duration')
                local payment_option=$(echo "$ri_instance" | jq -r '.PaymentOption')
                local offering_class=$(echo "$ri_instance" | jq -r '.OfferingClass')
                local hourly_charges=$(echo "$ri_instance" | jq -r '.UsagePrice')
                local platform=$(echo "$ri_instance" | jq -r '.ProductDescription')
                local state=$(echo "$ri_instance" | jq -r '.State')

                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$id" \
                    "$instance_type" \
                    "$scope" \
                    "$availability_zone" \
                    "$instance_count" \
                    "$start" \
                    "$expires" \
                    "$term" \
                    "$payment_option" \
                    "$offering_class" \
                    "$hourly_charges" \
                    "$platform" \
                    "$state" >> "$OUTPUT_FILE"
            done
        fi
        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Reserved Instances report saved to: $OUTPUT_FILE"
}

main "$@"
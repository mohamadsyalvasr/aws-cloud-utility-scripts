#!/bin/bash
# aws_sp_report.sh
# A standalone script to generate a detailed report on AWS Savings Plans.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_sp_report_$(date +"%Y%m%d-%H%M%S").csv"

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
                   Default: aws_sp_report_<timestamp>.csv
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

    # Create CSV header with the requested columns
    printf '"Saving Plans ID","Saving Plans Type","Instance Family","Payment Option","Commitment","Start date","End date","Notes"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local sp_data=$(aws savingsplans describe-savings-plans --region "$region" --query "savingsPlans[]" --output json)
        if [[ "$(echo "$sp_data" | jq 'length')" -eq 0 ]]; then
            log "  [SP] No Savings Plans found."
        else
            echo "$sp_data" | jq -c '.[]' | while read -r sp_plan; do
                local sp_id=$(echo "$sp_plan" | jq -r '.savingsPlanId')
                local sp_type=$(echo "$sp_plan" | jq -r '.savingsPlanType')
                local instance_family=$(echo "$sp_plan" | jq -r '.ec2InstanceFamily')
                local payment_option=$(echo "$sp_plan" | jq -r '.paymentOption')
                local commitment=$(echo "$sp_plan" | jq -r '.commitment')
                local start_time=$(echo "$sp_plan" | jq -r '.start')
                local end_time=$(echo "$sp_plan" | jq -r '.end')
                local notes="N/A"

                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$sp_id" \
                    "$sp_type" \
                    "$instance_family" \
                    "$payment_option" \
                    "$commitment" \
                    "$start_time" \
                    "$end_time" \
                    "$notes" >> "$OUTPUT_FILE"
            done
        fi
        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Savings Plans report saved to: $OUTPUT_FILE"
}

main "$@"
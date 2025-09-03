#!/bin/bash
# aws_sp_report.sh
# A standalone script to generate a detailed report on AWS Savings Plans.

# Exit immediately if a command fails
set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_sp_report_$(date +"%Y%m%d-%H%M%S").csv"

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Name of the output CSV file.
                   Default: aws_sp_report.csv
  -h               Show this help message.
EOF
    exit 1
}

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
printf '"Saving Plans ID","Saving Plans Type","Instance Family","Payment Option","Commitment","Start date","End date","Notes"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- Processing Saving Plans (SP) ---
    log "  [SP] Fetching Savings Plans data..."
    SP_DATA=$(aws savingsplans describe-savings-plans --region "$region" --query "savingsPlans[]" --output json)
    if [[ "$(echo "$SP_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [SP] No Savings Plans found."
    else
        echo "$SP_DATA" | jq -c '.[]' | while read -r sp_plan; do
            # Extract data from the JSON object
            SP_ID=$(echo "$sp_plan" | jq -r '.savingsPlanId')
            SP_TYPE=$(echo "$sp_plan" | jq -r '.savingsPlanType')
            INSTANCE_FAMILY=$(echo "$sp_plan" | jq -r '.ec2InstanceFamily')
            PAYMENT_OPTION=$(echo "$sp_plan" | jq -r '.paymentOption')
            COMMITMENT=$(echo "$sp_plan" | jq -r '.commitment')
            START_TIME=$(echo "$sp_plan" | jq -r '.start')
            END_TIME=$(echo "$sp_plan" | jq -r '.end')
            NOTES="N/A" # Default notes column

            # Print data row to the CSV file
            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$SP_ID" \
                "$SP_TYPE" \
                "$INSTANCE_FAMILY" \
                "$PAYMENT_OPTION" \
                "$COMMITMENT" \
                "$START_TIME" \
                "$END_TIME" \
                "$NOTES" >> "$OUTPUT_FILE"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Savings Plans report saved to: $OUTPUT_FILE"

#!/bin/bash
# aws_sp_report.sh
# A standalone script to generate a detailed report on AWS Savings Plans.
# NOTE: Savings Plans is a GLOBAL API (not per-region). We call it once.

# Exit immediately if a command fails
set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_sp_report.csv"

usage() {
    cat <<EOF >&2
Usage: $0 [-f filename]

Options:
  -f <filename>    Name of the output CSV file.
                   Default: aws_sp_report.csv
  -h               Show this help message.

Note: Savings Plans is a global API. No region loop is needed.
EOF
    exit 1
}

while getopts "f:h" opt; do
    case "$opt" in
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

mkdir -p "$(dirname "$OUTPUT_FILE")"

# Create CSV header with the requested columns
printf '"Saving Plans ID","Saving Plans Type","Instance Family","Payment Option","Commitment","Start date","End date","State","Notes"\n' > "$OUTPUT_FILE"

# Savings Plans is a global API - call once without region loop
log "  [SP] Fetching Savings Plans data (global)..."
SP_DATA=$(aws savingsplans describe-savings-plans --query "savingsPlans[]" --output json)
if [[ "$(echo "$SP_DATA" | jq 'length')" -eq 0 ]]; then
    log "  [SP] No Savings Plans found."
else
    echo "$SP_DATA" | jq -c '.[]' | while read -r sp_plan; do
        # Extract data from the JSON object
        SP_ID=$(echo "$sp_plan" | jq -r '.savingsPlanId')
        SP_TYPE=$(echo "$sp_plan" | jq -r '.savingsPlanType')
        INSTANCE_FAMILY=$(echo "$sp_plan" | jq -r '.ec2InstanceFamily // "N/A"')
        PAYMENT_OPTION=$(echo "$sp_plan" | jq -r '.paymentOption')
        COMMITMENT=$(echo "$sp_plan" | jq -r '.commitment')
        START_TIME=$(echo "$sp_plan" | jq -r '.start')
        END_TIME=$(echo "$sp_plan" | jq -r '.end')
        STATE=$(echo "$sp_plan" | jq -r '.state // "N/A"')
        NOTES="N/A" # Default notes column

        # Print data row to the CSV file
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$SP_ID" \
            "$SP_TYPE" \
            "$INSTANCE_FAMILY" \
            "$PAYMENT_OPTION" \
            "$COMMITMENT" \
            "$START_TIME" \
            "$END_TIME" \
            "$STATE" \
            "$NOTES" >> "$OUTPUT_FILE"
    done
fi

log "✅ DONE. Savings Plans report saved to: $OUTPUT_FILE"

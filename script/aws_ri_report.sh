#!/bin/bash
# aws_ri_report.sh
# A standalone script to generate a detailed report on AWS Reserved Instances (RI).

# Exit immediately if a command fails
set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_ri_report_$(date +"%Y%m%d-%H%M%S").csv"

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Name of the output CSV file.
                   Default: aws_ri_report.csv
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

# Create CSV header with all the new columns
printf '"ID","Instance Type","Scope","Availability Zone","Instance Count","Start","Expires","Term","Payment Option","Offering Class","Hourly Charges","Platform","State"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- Processing Reserved Instances (RI) ---
    log "  [RI] Fetching Reserved Instances data..."
    RI_DATA=$(aws ec2 describe-reserved-instances --region "$region" --query "ReservedInstances[]" --output json)
    if [[ "$(echo "$RI_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [RI] No Reserved Instances found."
    else
        echo "$RI_DATA" | jq -c '.[]' | while read -r ri_instance; do
            # Extract data from the JSON object
            ID=$(echo "$ri_instance" | jq -r '.ReservedInstancesId')
            INSTANCE_TYPE=$(echo "$ri_instance" | jq -r '.InstanceType')
            SCOPE=$(echo "$ri_instance" | jq -r '.Scope')
            AVAILABILITY_ZONE=$(echo "$ri_instance" | jq -r '.AvailabilityZone // "N/A"')
            INSTANCE_COUNT=$(echo "$ri_instance" | jq -r '.InstanceCount')
            START=$(echo "$ri_instance" | jq -r '.Start')
            EXPIRES=$(echo "$ri_instance" | jq -r '.End')
            TERM=$(echo "$ri_instance" | jq -r '.Duration')
            PAYMENT_OPTION=$(echo "$ri_instance" | jq -r '.PaymentOption')
            OFFERING_CLASS=$(echo "$ri_instance" | jq -r '.OfferingClass')
            HOURLY_CHARGES=$(echo "$ri_instance" | jq -r '.UsagePrice')
            PLATFORM=$(echo "$ri_instance" | jq -r '.ProductDescription')
            STATE=$(echo "$ri_instance" | jq -r '.State')

            # Print data row to the CSV file
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$ID" \
                "$INSTANCE_TYPE" \
                "$SCOPE" \
                "$AVAILABILITY_ZONE" \
                "$INSTANCE_COUNT" \
                "$START" \
                "$EXPIRES" \
                "$TERM" \
                "$PAYMENT_OPTION" \
                "$OFFERING_CLASS" \
                "$HOURLY_CHARGES" \
                "$PLATFORM" \
                "$STATE" >> "$OUTPUT_FILE"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Reserved Instances report saved to: $OUTPUT_FILE"

#!/bin/bash
# aws_sp_ri_report.sh
# Script to combine Savings Plans and Reserved Instances reports into a single CSV file.

# Exit immediately if a command fails
set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="../output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_sp_ri_report.csv"

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Name of the output CSV file.
                   Default: aws_sp_ri_report.csv
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

# Create CSV header with consistent formatting
printf '"Service","Identifier","Name","Type","Class","Engine","State","StartTime","EndTime","Region","CommitmentUSDperHr"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- Process Reserved Instances (RI) ---
    log "  [RI] Fetching Reserved Instances data..."
    # This command fetches RI data and ensures the output is in parsable JSON format
    RI_DATA=$(aws ec2 describe-reserved-instances --region "$region" --query "ReservedInstances[]" --output json)
    if [[ "$(echo "$RI_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [RI] No Reserved Instances found."
    else
        echo "$RI_DATA" | jq -c '.[]' | while read -r ri_instance; do
            # Extract data from the JSON object
            SERVICE="RI"
            ID=$(echo "$ri_instance" | jq -r '.ReservedInstancesId')
            NAME="N/A" # RIs do not have a Name tag by default
            TYPE=$(echo "$ri_instance" | jq -r '.InstanceType')
            CLASS="N/A"
            ENGINE="N/A"
            STATE=$(echo "$ri_instance" | jq -r '.State')
            START_TIME=$(echo "$ri_instance" | jq -r '.Start')
            END_TIME=$(echo "$ri_instance" | jq -r '.End')
            REGION_SCOPE=$(echo "$ri_instance" | jq -r '.AvailabilityZone // "Global"')
            COMMITMENT="N/A"

            # Print data row to the CSV file
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$SERVICE" \
                "$ID" \
                "$NAME" \
                "$TYPE" \
                "$CLASS" \
                "$ENGINE" \
                "$STATE" \
                "$START_TIME" \
                "$END_TIME" \
                "$REGION_SCOPE" \
                "$COMMITMENT" >> "$OUTPUT_FILE"
        done
    fi

    # --- Process Savings Plans (SP) ---
    log "  [SP] Fetching Savings Plans data..."
    # This command fetches SP data and ensures the output is in parsable JSON format
    SP_DATA=$(aws savingsplans describe-savings-plans --region "$region" --query "savingsPlans[]" --output json)
    if [[ "$(echo "$SP_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [SP] No Savings Plans found."
    else
        echo "$SP_DATA" | jq -c '.[]' | while read -r sp_plan; do
            # Extract data from the JSON object
            SERVICE="SP"
            ID=$(echo "$sp_plan" | jq -r '.savingsPlanId')
            NAME="N/A" # SPs do not have a Name tag by default
            TYPE=$(echo "$sp_plan" | jq -r '.savingsPlanType')
            CLASS="N/A"
            ENGINE="N/A"
            STATE=$(echo "$sp_plan" | jq -r '.state')
            START_TIME=$(echo "$sp_plan" | jq -r '.start')
            END_TIME=$(echo "$sp_plan" | jq -r '.end')
            REGION_SCOPE="Global"
            COMMITMENT=$(echo "$sp_plan" | jq -r '.commitment')

            # Print data row to the CSV file
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$SERVICE" \
                "$ID" \
                "$NAME" \
                "$TYPE" \
                "$CLASS" \
                "$ENGINE" \
                "$STATE" \
                "$START_TIME" \
                "$END_TIME" \
                "$REGION_SCOPE" \
                "$COMMITMENT" >> "$OUTPUT_FILE"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Combined report saved to: $OUTPUT_FILE"

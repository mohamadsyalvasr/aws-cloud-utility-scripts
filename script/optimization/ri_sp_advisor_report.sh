#!/bin/bash
# ri_sp_advisor_report.sh
# Recommends Reserved Instance or Savings Plans purchases based on consistent
# on-demand usage patterns. Identifies EC2 instances running continuously that
# are not covered by existing RIs or SPs, and calculates potential savings.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ri_sp_advisor_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""

# RI/SP discount percentages vs on-demand
DISCOUNT_1YR_NO_UPFRONT=0.36
DISCOUNT_1YR_ALL_UPFRONT=0.40
DISCOUNT_3YR_ALL_UPFRONT=0.60

# Source pricing helper for pricing functions
source ./lib/pricing_helper.sh

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for the analysis period (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for the analysis period (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions to scan. Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

# Add a log function for this script to be self-contained
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# Process command-line arguments
while getopts "b:e:r:f:h" opt; do
    case "$opt" in
        b)
            START_DATE="$OPTARG"
            ;;
        e)
            END_DATE="$OPTARG"
            ;;
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

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq, bc)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
    exit 1
fi
log "✅ Dependencies met."

log "📊 RI/SP Advisor Analysis"
log "   Analysis Period: $START_DATE to $END_DATE"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Instance ID","Instance Type","Current Monthly On-Demand Cost","1yr No Upfront Savings","1yr All Upfront Savings","3yr All Upfront Savings","Recommended Plan Type","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- Step 1: Get all running EC2 instances launched before the analysis start date ---
    INSTANCES_DATA=$(aws ec2 describe-instances --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[]' \
        --output json)

    INSTANCE_COUNT=$(echo "$INSTANCES_DATA" | jq 'length')

    if [[ "$INSTANCE_COUNT" -eq 0 ]]; then
        log "  [EC2] No running instances found."
        log "Region \033[1;33m$region\033[0m Complete."
        continue
    fi

    log "  Found $INSTANCE_COUNT running instance(s) in $region"

    # --- Step 2: Get active Reserved Instances for this region ---
    RI_DATA=$(aws ec2 describe-reserved-instances --region "$region" \
        --filters "Name=state,Values=active" \
        --output json 2>/dev/null || echo '{"ReservedInstances":[]}')

    RI_COUNT=$(echo "$RI_DATA" | jq '.ReservedInstances | length')
    log "  Found $RI_COUNT active Reserved Instance(s) in $region"

    # Build a lookup of RI coverage: instance_type|az -> remaining count
    declare -A RI_COVERAGE=()
    if [[ "$RI_COUNT" -gt 0 ]]; then
        while IFS='|' read -r ri_type ri_az ri_count; do
            key="${ri_type}|${ri_az}"
            existing="${RI_COVERAGE[$key]:-0}"
            RI_COVERAGE[$key]=$((existing + ri_count))
        done < <(echo "$RI_DATA" | jq -r '.ReservedInstances[] | "\(.InstanceType)|\(.AvailabilityZone)|\(.InstanceCount)"')
    fi

    # --- Step 3: Get active Savings Plans (if available) ---
    SP_INSTANCE_TYPES=()
    SP_DATA=$(aws savingsplans describe-savings-plans \
        --states active \
        --output json 2>/dev/null || echo '{"savingsPlans":[]}')

    SP_COUNT=$(echo "$SP_DATA" | jq '.savingsPlans | length')
    log "  Found $SP_COUNT active Savings Plan(s)"

    # --- Step 4: Process each running instance ---
    echo "$INSTANCES_DATA" | jq -c '.[]' | while read -r instance; do
        INSTANCE_ID=$(echo "$instance" | jq -r '.InstanceId')
        INSTANCE_TYPE=$(echo "$instance" | jq -r '.InstanceType')
        LAUNCH_TIME=$(echo "$instance" | jq -r '.LaunchTime')
        AVAILABILITY_ZONE=$(echo "$instance" | jq -r '.Placement.AvailabilityZone')

        # Check if instance was launched before the analysis start date (running continuously)
        LAUNCH_EPOCH=$(date -u -d "$LAUNCH_TIME" +%s 2>/dev/null || echo "0")
        START_EPOCH=$(date -u -d "$START_DATE 00:00:00" +%s 2>/dev/null || echo "0")

        if [[ "$LAUNCH_EPOCH" -ge "$START_EPOCH" ]]; then
            # Instance was launched during or after the analysis period - skip
            continue
        fi

        # --- Step 5: Check RI coverage ---
        RI_KEY="${INSTANCE_TYPE}|${AVAILABILITY_ZONE}"
        RI_REMAINING="${RI_COVERAGE[$RI_KEY]:-0}"

        if [[ "$RI_REMAINING" -gt 0 ]]; then
            # Instance is covered by an RI - decrement count and skip
            RI_COVERAGE[$RI_KEY]=$((RI_REMAINING - 1))
            log "    ⏭️ $INSTANCE_ID covered by RI ($INSTANCE_TYPE in $AVAILABILITY_ZONE)"
            continue
        fi

        # --- Step 6: Check Savings Plan coverage ---
        # If there are active Compute Savings Plans, they cover all instance types.
        # For simplicity, if any active SP exists, we check if it's a Compute SP.
        SP_COVERED=false
        if [[ "$SP_COUNT" -gt 0 ]]; then
            # Check if any Compute Savings Plan exists (covers all EC2 usage)
            COMPUTE_SP_COUNT=$(echo "$SP_DATA" | jq '[.savingsPlans[] | select(.savingsPlanType == "Compute")] | length')
            if [[ "$COMPUTE_SP_COUNT" -gt 0 ]]; then
                SP_COVERED=true
            fi

            # Check if any EC2 Instance Savings Plan covers this instance type in this region
            if [[ "$SP_COVERED" == "false" ]]; then
                EC2_SP_MATCH=$(echo "$SP_DATA" | jq --arg region "$region" \
                    '[.savingsPlans[] | select(.savingsPlanType == "EC2Instance" and .region == $region)] | length')
                if [[ "$EC2_SP_MATCH" -gt 0 ]]; then
                    SP_COVERED=true
                fi
            fi
        fi

        if [[ "$SP_COVERED" == "true" ]]; then
            log "    ⏭️ $INSTANCE_ID covered by Savings Plan"
            continue
        fi

        # --- Step 7: Calculate savings ---
        HOURLY_PRICE=$(get_ec2_price "$INSTANCE_TYPE" "$region") || true

        if [[ -z "$HOURLY_PRICE" || "$HOURLY_PRICE" == "null" ]]; then
            log "    ⚠️ Pricing data unavailable for $INSTANCE_TYPE in $region"
            continue
        fi

        # Monthly on-demand cost = hourly price * 730 hours
        MONTHLY_COST=$(echo "$HOURLY_PRICE * 730" | bc -l | xargs printf "%.2f")

        # Calculate savings for each commitment option
        SAVINGS_1YR_NO_UPFRONT=$(echo "$MONTHLY_COST * $DISCOUNT_1YR_NO_UPFRONT" | bc -l | xargs printf "%.2f")
        SAVINGS_1YR_ALL_UPFRONT=$(echo "$MONTHLY_COST * $DISCOUNT_1YR_ALL_UPFRONT" | bc -l | xargs printf "%.2f")
        SAVINGS_3YR_ALL_UPFRONT=$(echo "$MONTHLY_COST * $DISCOUNT_3YR_ALL_UPFRONT" | bc -l | xargs printf "%.2f")

        # Recommended plan type: default to Reserved Instance for consistent usage
        RECOMMENDED_PLAN="Reserved Instance"

        log "    💰 $INSTANCE_ID ($INSTANCE_TYPE): On-Demand \$${MONTHLY_COST}/mo, potential 3yr savings \$${SAVINGS_3YR_ALL_UPFRONT}/mo"

        printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$INSTANCE_ID" \
            "$INSTANCE_TYPE" \
            "$MONTHLY_COST" \
            "$SAVINGS_1YR_NO_UPFRONT" \
            "$SAVINGS_1YR_ALL_UPFRONT" \
            "$SAVINGS_3YR_ALL_UPFRONT" \
            "$RECOMMENDED_PLAN" \
            "$region" >> "$OUTPUT_FILE"
    done

    # Clear associative array for next region
    unset RI_COVERAGE

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. RI/SP Advisor report saved to: $OUTPUT_FILE"

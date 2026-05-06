#!/bin/bash
# ec2_rightsizing_report.sh
# Generates a report on EC2 instances that are over-provisioned based on CPU and memory utilization,
# recommending right-sizing to reduce costs.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ec2_rightsizing_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # 30 days in seconds
UTIL_THRESHOLD="${UTIL_THRESHOLD:-30}"

# Source pricing helper for pricing functions
source ./lib/pricing_helper.sh

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for utilization metrics (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for utilization metrics (YYYY-MM-DD).
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

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."
    exit 1
fi
log "✅ Dependencies met."

log "📊 EC2 Right-Sizing Analysis (Threshold: ${UTIL_THRESHOLD}%)"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Instance ID","Instance Name","Current Type","Avg CPU %%","Avg Memory %%","Recommended Type","Current Monthly Cost","Recommended Monthly Cost","Estimated Monthly Savings","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all running EC2 instances
    INSTANCES_DATA=$(aws ec2 describe-instances --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[]' \
        --output json)

    INSTANCE_COUNT=$(echo "$INSTANCES_DATA" | jq 'length')

    if [[ "$INSTANCE_COUNT" -gt 0 ]]; then
        log "  Found $INSTANCE_COUNT running instance(s) in $region"

        echo "$INSTANCES_DATA" | jq -c '.[]' | while read -r instance; do
            INSTANCE_ID=$(echo "$instance" | jq -r '.InstanceId')
            INSTANCE_TYPE=$(echo "$instance" | jq -r '.InstanceType')
            INSTANCE_NAME=$(echo "$instance" | jq -r '(.Tags // [])[] | select(.Key == "Name") | .Value // "N/A"')
            INSTANCE_NAME="${INSTANCE_NAME:-N/A}"

            log "  Analyzing instance: $INSTANCE_ID ($INSTANCE_TYPE)"

            # Get average CPU utilization from CloudWatch
            AVG_CPU=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name CPUUtilization \
                --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                --output text)

            # Get average memory utilization from CloudWatch Agent
            AVG_MEMORY=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace CWAgent \
                --metric-name mem_used_percent \
                --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                --output text)

            # Handle null/None values
            AVG_CPU=${AVG_CPU:-"N/A"}
            if [ "$AVG_CPU" = "null" ] || [ "$AVG_CPU" = "None" ]; then
                AVG_CPU="N/A"
            fi

            AVG_MEMORY=${AVG_MEMORY:-"N/A"}
            if [ "$AVG_MEMORY" = "null" ] || [ "$AVG_MEMORY" = "None" ]; then
                AVG_MEMORY="N/A"
            fi

            # Determine if instance has sufficient data for recommendation
            if [ "$AVG_CPU" = "N/A" ] || [ "$AVG_MEMORY" = "N/A" ]; then
                # Insufficient data - skip recommendation
                RECOMMENDED_TYPE="Insufficient Data"
                CURRENT_MONTHLY_COST="N/A"
                RECOMMENDED_MONTHLY_COST="N/A"
                ESTIMATED_SAVINGS="N/A"
                log "    ⚠️ Insufficient metrics data for $INSTANCE_ID"
            else
                # Check if BOTH CPU and Memory are below threshold
                CPU_BELOW=$(echo "$AVG_CPU < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")
                MEM_BELOW=$(echo "$AVG_MEMORY < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")

                if [ "$CPU_BELOW" = "1" ] && [ "$MEM_BELOW" = "1" ]; then
                    # Instance is underutilized - recommend downsizing
                    RECOMMENDED_TYPE=$(get_next_smaller_ec2_type "$INSTANCE_TYPE") || true

                    if [ -z "$RECOMMENDED_TYPE" ]; then
                        # Already at smallest size
                        RECOMMENDED_TYPE="Already smallest"
                        CURRENT_MONTHLY_COST="N/A"
                        RECOMMENDED_MONTHLY_COST="N/A"
                        ESTIMATED_SAVINGS="N/A"
                        log "    ℹ️ $INSTANCE_ID is already at smallest size in family"
                    else
                        # Get pricing for current and recommended types
                        CURRENT_PRICE=$(get_ec2_price "$INSTANCE_TYPE" "$region") || true
                        RECOMMENDED_PRICE=$(get_ec2_price "$RECOMMENDED_TYPE" "$region") || true

                        if [ -n "$CURRENT_PRICE" ] && [ -n "$RECOMMENDED_PRICE" ]; then
                            # Calculate monthly costs (hourly * 730 hours/month)
                            CURRENT_MONTHLY_COST=$(echo "$CURRENT_PRICE * 730" | bc -l | xargs printf "%.2f")
                            RECOMMENDED_MONTHLY_COST=$(echo "$RECOMMENDED_PRICE * 730" | bc -l | xargs printf "%.2f")
                            ESTIMATED_SAVINGS=$(echo "($CURRENT_PRICE - $RECOMMENDED_PRICE) * 730" | bc -l | xargs printf "%.2f")

                            # Ensure savings is non-negative
                            SAVINGS_NEGATIVE=$(echo "$ESTIMATED_SAVINGS < 0" | bc -l 2>/dev/null || echo "0")
                            if [ "$SAVINGS_NEGATIVE" = "1" ]; then
                                ESTIMATED_SAVINGS="0.00"
                            fi

                            log "    💰 Potential savings: \$${ESTIMATED_SAVINGS}/month ($INSTANCE_TYPE → $RECOMMENDED_TYPE)"
                        else
                            CURRENT_MONTHLY_COST="N/A"
                            RECOMMENDED_MONTHLY_COST="N/A"
                            ESTIMATED_SAVINGS="N/A"
                            log "    ⚠️ Pricing data unavailable for $INSTANCE_TYPE or $RECOMMENDED_TYPE"
                        fi
                    fi
                else
                    # Instance is not underutilized - no recommendation
                    RECOMMENDED_TYPE="N/A"
                    # Still get current cost for reference
                    CURRENT_PRICE=$(get_ec2_price "$INSTANCE_TYPE" "$region") || true
                    if [ -n "$CURRENT_PRICE" ]; then
                        CURRENT_MONTHLY_COST=$(echo "$CURRENT_PRICE * 730" | bc -l | xargs printf "%.2f")
                    else
                        CURRENT_MONTHLY_COST="N/A"
                    fi
                    RECOMMENDED_MONTHLY_COST="N/A"
                    ESTIMATED_SAVINGS="0.00"
                fi
            fi

            # Format CPU and Memory values for output
            if [ "$AVG_CPU" != "N/A" ]; then
                AVG_CPU=$(printf "%.2f" "$AVG_CPU")
            fi
            if [ "$AVG_MEMORY" != "N/A" ]; then
                AVG_MEMORY=$(printf "%.2f" "$AVG_MEMORY")
            fi

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$INSTANCE_ID" \
                "$INSTANCE_NAME" \
                "$INSTANCE_TYPE" \
                "$AVG_CPU" \
                "$AVG_MEMORY" \
                "$RECOMMENDED_TYPE" \
                "$CURRENT_MONTHLY_COST" \
                "$RECOMMENDED_MONTHLY_COST" \
                "$ESTIMATED_SAVINGS" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [EC2] No running instances found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. EC2 Right-Sizing report saved to: $OUTPUT_FILE"

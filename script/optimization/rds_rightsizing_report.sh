#!/bin/bash
# rds_rightsizing_report.sh
# Generates a report on RDS instances that are over-provisioned based on CPU and memory utilization,
# recommending right-sizing to reduce costs.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/rds_rightsizing_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # 30 days in seconds
UTIL_THRESHOLD="${UTIL_THRESHOLD:-30}"
MEMORY_FREE_THRESHOLD="${MEMORY_FREE_THRESHOLD:-70}"

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
log "🔎 Checking dependencies (aws cli, jq, bc)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
    exit 1
fi
log "✅ Dependencies met."

log "📊 RDS Right-Sizing Analysis (CPU Threshold: ${UTIL_THRESHOLD}%, Freeable Memory Threshold: ${MEMORY_FREE_THRESHOLD}%)"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"DB Instance ID","Engine","Current Class","Avg CPU %%","Avg Freeable Memory %%","Avg Free Storage %%","Recommended Class","Current Monthly Cost","Recommended Monthly Cost","Estimated Monthly Savings","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all RDS instances
    INSTANCES_DATA=$(aws rds describe-db-instances --region "$region" \
        --query 'DBInstances[]' \
        --output json)

    INSTANCE_COUNT=$(echo "$INSTANCES_DATA" | jq 'length')

    if [[ "$INSTANCE_COUNT" -gt 0 ]]; then
        log "  Found $INSTANCE_COUNT RDS instance(s) in $region"

        echo "$INSTANCES_DATA" | jq -c '.[]' | while read -r instance; do
            DB_INSTANCE_ID=$(echo "$instance" | jq -r '.DBInstanceIdentifier')
            DB_ENGINE=$(echo "$instance" | jq -r '.Engine')
            DB_CLASS=$(echo "$instance" | jq -r '.DBInstanceClass')
            MULTI_AZ=$(echo "$instance" | jq -r '.MultiAZ')
            ALLOCATED_STORAGE=$(echo "$instance" | jq -r '.AllocatedStorage') # in GiB

            log "  Analyzing instance: $DB_INSTANCE_ID ($DB_CLASS, Engine: $DB_ENGINE, MultiAZ: $MULTI_AZ)"

            # Get average CPU utilization from CloudWatch
            AVG_CPU=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name CPUUtilization \
                --dimensions Name=DBInstanceIdentifier,Value="$DB_INSTANCE_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                --output text)

            # Get average FreeableMemory from CloudWatch (in bytes)
            AVG_FREEABLE_MEMORY=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name FreeableMemory \
                --dimensions Name=DBInstanceIdentifier,Value="$DB_INSTANCE_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
                --output text)

            # Get average FreeStorageSpace from CloudWatch (in bytes)
            AVG_FREE_STORAGE=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name FreeStorageSpace \
                --dimensions Name=DBInstanceIdentifier,Value="$DB_INSTANCE_ID" \
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

            AVG_FREEABLE_MEMORY=${AVG_FREEABLE_MEMORY:-"N/A"}
            if [ "$AVG_FREEABLE_MEMORY" = "null" ] || [ "$AVG_FREEABLE_MEMORY" = "None" ]; then
                AVG_FREEABLE_MEMORY="N/A"
            fi

            AVG_FREE_STORAGE=${AVG_FREE_STORAGE:-"N/A"}
            if [ "$AVG_FREE_STORAGE" = "null" ] || [ "$AVG_FREE_STORAGE" = "None" ]; then
                AVG_FREE_STORAGE="N/A"
            fi

            # Calculate Freeable Memory as a percentage
            # We use the raw FreeableMemory metric value as "Avg Freeable Memory %"
            # since determining total memory per RDS class is complex
            FREEABLE_MEMORY_PCT="N/A"
            if [ "$AVG_FREEABLE_MEMORY" != "N/A" ]; then
                # Convert FreeableMemory from bytes to a percentage estimate
                # Use the metric directly as a percentage indicator (higher = more free = underutilized)
                # FreeableMemory is in bytes; we report it as a rough % by estimating total memory from class
                # Simpler approach: report raw value converted to GB for context, but use threshold logic
                # For threshold comparison, treat FreeableMemory > 70% as underutilized
                # We estimate total memory based on instance class size
                FREEABLE_MEMORY_PCT=$(echo "scale=2; $AVG_FREEABLE_MEMORY / 1073741824" | bc -l 2>/dev/null || echo "N/A")
                if [ "$FREEABLE_MEMORY_PCT" != "N/A" ]; then
                    # Estimate total memory based on instance size for percentage calculation
                    # Common RDS memory: micro=1GB, small=2GB, medium=4GB, large=8GB, xlarge=16GB, 2xlarge=32GB, 4xlarge=64GB, 8xlarge=128GB, 12xlarge=192GB, 16xlarge=256GB, 24xlarge=384GB
                    INSTANCE_SIZE=$(echo "$DB_CLASS" | cut -d'.' -f3)
                    case "$INSTANCE_SIZE" in
                        nano)     TOTAL_MEMORY_GB=0.5 ;;
                        micro)    TOTAL_MEMORY_GB=1 ;;
                        small)    TOTAL_MEMORY_GB=2 ;;
                        medium)   TOTAL_MEMORY_GB=4 ;;
                        large)    TOTAL_MEMORY_GB=8 ;;
                        xlarge)   TOTAL_MEMORY_GB=16 ;;
                        2xlarge)  TOTAL_MEMORY_GB=32 ;;
                        4xlarge)  TOTAL_MEMORY_GB=64 ;;
                        8xlarge)  TOTAL_MEMORY_GB=128 ;;
                        12xlarge) TOTAL_MEMORY_GB=192 ;;
                        16xlarge) TOTAL_MEMORY_GB=256 ;;
                        24xlarge) TOTAL_MEMORY_GB=384 ;;
                        *)        TOTAL_MEMORY_GB=8 ;; # default estimate
                    esac
                    FREEABLE_MEMORY_PCT=$(echo "scale=2; ($AVG_FREEABLE_MEMORY / 1073741824) / $TOTAL_MEMORY_GB * 100" | bc -l 2>/dev/null || echo "N/A")
                fi
            fi

            # Calculate Free Storage as a percentage of allocated storage
            FREE_STORAGE_PCT="N/A"
            if [ "$AVG_FREE_STORAGE" != "N/A" ] && [ "$ALLOCATED_STORAGE" != "null" ] && [ "$ALLOCATED_STORAGE" -gt 0 ] 2>/dev/null; then
                # Convert FreeStorageSpace from bytes to GiB and calculate percentage
                FREE_STORAGE_PCT=$(echo "scale=2; ($AVG_FREE_STORAGE / 1073741824) / $ALLOCATED_STORAGE * 100" | bc -l 2>/dev/null || echo "N/A")
            fi

            # Determine if instance has sufficient data for recommendation
            if [ "$AVG_CPU" = "N/A" ] || [ "$FREEABLE_MEMORY_PCT" = "N/A" ]; then
                # Insufficient data - skip recommendation
                RECOMMENDED_CLASS="Insufficient Data"
                CURRENT_MONTHLY_COST="N/A"
                RECOMMENDED_MONTHLY_COST="N/A"
                ESTIMATED_SAVINGS="N/A"
                log "    ⚠️ Insufficient metrics data for $DB_INSTANCE_ID"
            else
                # Check if CPU is below threshold AND freeable memory is above 70% (meaning lots of free memory = underutilized)
                CPU_BELOW=$(echo "$AVG_CPU < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")
                MEM_FREE_HIGH=$(echo "$FREEABLE_MEMORY_PCT > $MEMORY_FREE_THRESHOLD" | bc -l 2>/dev/null || echo "0")

                if [ "$CPU_BELOW" = "1" ] && [ "$MEM_FREE_HIGH" = "1" ]; then
                    # Instance is underutilized - recommend downsizing
                    RECOMMENDED_CLASS=$(get_next_smaller_rds_class "$DB_CLASS") || true

                    if [ -z "$RECOMMENDED_CLASS" ]; then
                        # Already at smallest size
                        RECOMMENDED_CLASS="Already smallest"
                        CURRENT_MONTHLY_COST="N/A"
                        RECOMMENDED_MONTHLY_COST="N/A"
                        ESTIMATED_SAVINGS="N/A"
                        log "    ℹ️ $DB_INSTANCE_ID is already at smallest size in family"
                    else
                        # Get pricing for current and recommended classes
                        CURRENT_PRICE=$(get_rds_price "$DB_CLASS" "$region") || true
                        RECOMMENDED_PRICE=$(get_rds_price "$RECOMMENDED_CLASS" "$region") || true

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

                            # Double savings for Multi-AZ deployments
                            if [ "$MULTI_AZ" = "true" ]; then
                                ESTIMATED_SAVINGS=$(echo "$ESTIMATED_SAVINGS * 2" | bc -l | xargs printf "%.2f")
                                log "    📌 Multi-AZ deployment detected - doubling savings estimate"
                            fi

                            log "    💰 Potential savings: \$${ESTIMATED_SAVINGS}/month ($DB_CLASS → $RECOMMENDED_CLASS)"
                        else
                            CURRENT_MONTHLY_COST="N/A"
                            RECOMMENDED_MONTHLY_COST="N/A"
                            ESTIMATED_SAVINGS="N/A"
                            log "    ⚠️ Pricing data unavailable for $DB_CLASS or $RECOMMENDED_CLASS"
                        fi
                    fi
                else
                    # Instance is not underutilized - no recommendation
                    RECOMMENDED_CLASS="N/A"
                    # Still get current cost for reference
                    CURRENT_PRICE=$(get_rds_price "$DB_CLASS" "$region") || true
                    if [ -n "$CURRENT_PRICE" ]; then
                        CURRENT_MONTHLY_COST=$(echo "$CURRENT_PRICE * 730" | bc -l | xargs printf "%.2f")
                    else
                        CURRENT_MONTHLY_COST="N/A"
                    fi
                    RECOMMENDED_MONTHLY_COST="N/A"
                    ESTIMATED_SAVINGS="0.00"
                fi
            fi

            # Format values for output
            if [ "$AVG_CPU" != "N/A" ]; then
                AVG_CPU=$(printf "%.2f" "$AVG_CPU")
            fi
            if [ "$FREEABLE_MEMORY_PCT" != "N/A" ]; then
                FREEABLE_MEMORY_PCT=$(printf "%.2f" "$FREEABLE_MEMORY_PCT")
            fi
            if [ "$FREE_STORAGE_PCT" != "N/A" ]; then
                FREE_STORAGE_PCT=$(printf "%.2f" "$FREE_STORAGE_PCT")
            fi

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$DB_INSTANCE_ID" \
                "$DB_ENGINE" \
                "$DB_CLASS" \
                "$AVG_CPU" \
                "$FREEABLE_MEMORY_PCT" \
                "$FREE_STORAGE_PCT" \
                "$RECOMMENDED_CLASS" \
                "$CURRENT_MONTHLY_COST" \
                "$RECOMMENDED_MONTHLY_COST" \
                "$ESTIMATED_SAVINGS" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [RDS] No instances found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. RDS Right-Sizing report saved to: $OUTPUT_FILE"

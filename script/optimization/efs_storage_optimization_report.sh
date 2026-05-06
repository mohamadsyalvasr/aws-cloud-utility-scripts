#!/bin/bash
# efs_storage_optimization_report.sh
# Generates a report on EFS file systems with low utilization or suboptimal storage class
# configurations, recommending Lifecycle Management and storage class transitions to reduce costs.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/efs_storage_optimization_report.csv"
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

# --- Helper Functions ---

# Get EFS pricing from fallback JSON
get_efs_price() {
    local price_key="$1"
    local region="$2"

    if [[ ! -f "$PRICING_FALLBACK_FILE" ]]; then
        echo ""
        return 1
    fi

    local price=""
    price=$(jq -r ".efs.\"${region}\".\"${price_key}\" // empty" "$PRICING_FALLBACK_FILE" 2>/dev/null)
    echo "$price"
}

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq, bc)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
    exit 1
fi
log "✅ Dependencies met."

log "📊 EFS Storage Optimization Analysis (Threshold: ${UTIL_THRESHOLD}%)"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"File System ID","Name","Total Size GiB","Size in Standard GiB","Size in IA GiB","Throughput Utilization %%","Lifecycle Policy Enabled","Recommendation","Estimated Monthly Savings","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all EFS file systems in this region
    EFS_DATA=$(aws efs describe-file-systems --region "$region" \
        --query 'FileSystems[]' \
        --output json 2>/dev/null) || {
        log "  ⚠️ Failed to describe EFS file systems in $region. Skipping."
        continue
    }

    EFS_COUNT=$(echo "$EFS_DATA" | jq 'length')

    if [[ "$EFS_COUNT" -gt 0 ]]; then
        log "  Found $EFS_COUNT EFS file system(s) in $region"

        EFS_IDX=0
        echo "$EFS_DATA" | jq -c '.[]' | while read -r fs; do
            EFS_IDX=$((EFS_IDX + 1))
            FS_ID=$(echo "$fs" | jq -r '.FileSystemId')
            FS_NAME=$(echo "$fs" | jq -r '(.Tags // [])[] | select(.Key == "Name") | .Value // "N/A"')
            FS_NAME="${FS_NAME:-N/A}"

            # Get size breakdown from SizeInBytes
            TOTAL_SIZE_BYTES=$(echo "$fs" | jq -r '.SizeInBytes.Value // 0')
            STANDARD_SIZE_BYTES=$(echo "$fs" | jq -r '.SizeInBytes.ValueInStandard // 0')
            IA_SIZE_BYTES=$(echo "$fs" | jq -r '.SizeInBytes.ValueInIA // 0')

            # Get creation time for "provisioned > 30 days" check
            CREATION_TOKEN=$(echo "$fs" | jq -r '.CreationTime // empty')

            log "  [$EFS_IDX/$EFS_COUNT] Analyzing: $FS_ID ($FS_NAME)"

            # Convert sizes to GiB (1 GiB = 1073741824 bytes)
            TOTAL_SIZE_GIB=$(echo "$TOTAL_SIZE_BYTES / 1073741824" | bc -l | xargs printf "%.2f")
            STANDARD_SIZE_GIB=$(echo "$STANDARD_SIZE_BYTES / 1073741824" | bc -l | xargs printf "%.2f")
            IA_SIZE_GIB=$(echo "$IA_SIZE_BYTES / 1073741824" | bc -l | xargs printf "%.2f")

            # --- Check Lifecycle Management policy ---
            LIFECYCLE_ENABLED="No"
            LIFECYCLE_CONFIG=$(aws efs describe-lifecycle-configuration \
                --file-system-id "$FS_ID" \
                --region "$region" \
                --output json 2>/dev/null) || true

            if [[ -n "$LIFECYCLE_CONFIG" ]]; then
                # Check if LifecyclePolicies array contains TransitionToIA
                HAS_TRANSITION_TO_IA=$(echo "$LIFECYCLE_CONFIG" | jq -r '.LifecyclePolicies[]? | select(.TransitionToIA != null) | .TransitionToIA' 2>/dev/null)
                if [[ -n "$HAS_TRANSITION_TO_IA" ]]; then
                    LIFECYCLE_ENABLED="Yes"
                fi
            fi

            # --- Get throughput utilization from CloudWatch ---
            # TotalIOBytes (Sum) represents total I/O throughput
            TOTAL_IO_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EFS \
                --metric-name TotalIOBytes \
                --dimensions Name=FileSystemId,Value="$FS_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "sort_by(Datapoints, &Timestamp)[-1].Sum" \
                --output text 2>/dev/null) || true

            # Handle null/None values for throughput
            if [[ -z "$TOTAL_IO_BYTES" || "$TOTAL_IO_BYTES" == "None" || "$TOTAL_IO_BYTES" == "null" ]]; then
                THROUGHPUT_UTIL="N/A"
            else
                # Calculate throughput utilization as percentage of burst throughput
                # EFS burst throughput baseline: 50 MiB/s per TiB of Standard storage
                # For the analysis period, calculate average throughput vs allowed burst
                STANDARD_SIZE_TIB=$(echo "$STANDARD_SIZE_BYTES / 1099511627776" | bc -l)
                if [[ $(echo "$STANDARD_SIZE_TIB < 0.001" | bc -l) -eq 1 ]]; then
                    # Very small file system - use minimum burst of 100 KiB/s
                    BURST_BYTES_PER_PERIOD=$(echo "102400 * $PERIOD" | bc -l)
                else
                    # Burst throughput: 50 MiB/s per TiB
                    BURST_BYTES_PER_SEC=$(echo "$STANDARD_SIZE_TIB * 52428800" | bc -l)
                    BURST_BYTES_PER_PERIOD=$(echo "$BURST_BYTES_PER_SEC * $PERIOD" | bc -l)
                fi

                if [[ $(echo "$BURST_BYTES_PER_PERIOD > 0" | bc -l) -eq 1 ]]; then
                    THROUGHPUT_UTIL=$(echo "$TOTAL_IO_BYTES / $BURST_BYTES_PER_PERIOD * 100" | bc -l | xargs printf "%.2f")
                else
                    THROUGHPUT_UTIL="0.00"
                fi
            fi

            # --- Determine recommendation ---
            RECOMMENDATION="None"
            ESTIMATED_SAVINGS="0.00"

            # Get EFS pricing for the region
            PRICE_STANDARD=$(get_efs_price "standard_per_gb" "$region")
            PRICE_IA=$(get_efs_price "infrequent_access_per_gb" "$region")

            # Default pricing if not available in fallback
            PRICE_STANDARD="${PRICE_STANDARD:-0.30}"
            PRICE_IA="${PRICE_IA:-0.025}"

            # Check if metrics are available
            if [[ "$THROUGHPUT_UTIL" == "N/A" ]]; then
                # Insufficient data - skip recommendation
                RECOMMENDATION="Insufficient Data"
                ESTIMATED_SAVINGS="N/A"
                log "    ⚠️ Insufficient metrics data for $FS_ID"
            else
                # Check if file system is provisioned for more than 30 days
                PROVISIONED_OVER_30_DAYS=false
                if [[ -n "$CREATION_TOKEN" ]]; then
                    CREATION_EPOCH=$(date -u -d "$CREATION_TOKEN" +%s 2>/dev/null) || CREATION_EPOCH=0
                    CURRENT_EPOCH=$(date -u +%s)
                    DAYS_PROVISIONED=$(( (CURRENT_EPOCH - CREATION_EPOCH) / 86400 ))
                    if [[ "$DAYS_PROVISIONED" -gt 30 ]]; then
                        PROVISIONED_OVER_30_DAYS=true
                    fi
                fi

                # Check: Total size < 1 GB + provisioned > 30 days = potentially unused
                TOTAL_SIZE_GB_NUM=$(echo "$TOTAL_SIZE_BYTES / 1073741824" | bc -l)
                if [[ $(echo "$TOTAL_SIZE_GB_NUM < 1" | bc -l) -eq 1 ]] && [[ "$PROVISIONED_OVER_30_DAYS" == "true" ]]; then
                    RECOMMENDATION="Potentially unused - review"
                    ESTIMATED_SAVINGS="0.00"
                    log "    ⚠️ $FS_ID appears potentially unused (< 1 GB, provisioned > 30 days)"
                else
                    # Check: Standard ratio > 80% + throughput below UTIL_THRESHOLD
                    STANDARD_RATIO=0
                    if [[ $(echo "$TOTAL_SIZE_BYTES > 0" | bc -l) -eq 1 ]]; then
                        STANDARD_RATIO=$(echo "$STANDARD_SIZE_BYTES / $TOTAL_SIZE_BYTES * 100" | bc -l | xargs printf "%.0f")
                    fi

                    THROUGHPUT_BELOW_THRESHOLD=$(echo "$THROUGHPUT_UTIL < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")

                    if [[ "$STANDARD_RATIO" -gt 80 ]] && [[ "$THROUGHPUT_BELOW_THRESHOLD" == "1" ]]; then
                        # Recommend enabling Lifecycle Management
                        RECOMMENDATION="Enable Lifecycle Management"

                        # Calculate savings: eligible_data_GB * (standard_price - ia_price)
                        # Eligible data = Standard data that could transition to IA
                        # Assume 50% of Standard data is eligible (conservative estimate)
                        ELIGIBLE_DATA_GB=$(echo "$STANDARD_SIZE_BYTES / 1073741824 * 0.50" | bc -l)
                        ESTIMATED_SAVINGS=$(echo "$ELIGIBLE_DATA_GB * ($PRICE_STANDARD - $PRICE_IA)" | bc -l | xargs printf "%.2f")

                        log "    💰 Recommendation: Enable Lifecycle Management | Savings: \$${ESTIMATED_SAVINGS}/month"
                    fi
                fi

                # Ensure savings is non-negative
                if [[ "$ESTIMATED_SAVINGS" != "N/A" && -n "$ESTIMATED_SAVINGS" ]]; then
                    SAVINGS_NEGATIVE=$(echo "$ESTIMATED_SAVINGS < 0" | bc -l 2>/dev/null || echo "0")
                    if [[ "$SAVINGS_NEGATIVE" == "1" ]]; then
                        ESTIMATED_SAVINGS="0.00"
                    fi
                fi
            fi

            # Format throughput utilization for output
            if [[ "$THROUGHPUT_UTIL" != "N/A" ]]; then
                THROUGHPUT_UTIL=$(printf "%.2f" "$THROUGHPUT_UTIL")
            fi

            log "    📦 Total: ${TOTAL_SIZE_GIB} GiB | Standard: ${STANDARD_SIZE_GIB} GiB | IA: ${IA_SIZE_GIB} GiB | Throughput: ${THROUGHPUT_UTIL}% | Lifecycle: ${LIFECYCLE_ENABLED}"

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$FS_ID" \
                "$FS_NAME" \
                "$TOTAL_SIZE_GIB" \
                "$STANDARD_SIZE_GIB" \
                "$IA_SIZE_GIB" \
                "$THROUGHPUT_UTIL" \
                "$LIFECYCLE_ENABLED" \
                "$RECOMMENDATION" \
                "$ESTIMATED_SAVINGS" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [EFS] No file systems found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. EFS Storage Optimization report saved to: $OUTPUT_FILE"

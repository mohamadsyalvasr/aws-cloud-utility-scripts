#!/bin/bash
# ebs_optimization_report.sh
# Generates a report on EBS volumes that are over-provisioned or using expensive volume types,
# recommending optimizations such as gp2→gp3 migration and IOPS reduction to reduce costs.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ebs_optimization_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # 30 days in seconds
UTIL_THRESHOLD="${UTIL_THRESHOLD:-30}"

# Source pricing helper for pricing functions
source ./lib/pricing_helper.sh

# Max throughput by volume type (MB/s) for utilization calculation
declare -A MAX_THROUGHPUT_MBPS
MAX_THROUGHPUT_MBPS[gp2]=250
MAX_THROUGHPUT_MBPS[gp3]=1000
MAX_THROUGHPUT_MBPS[io1]=1000
MAX_THROUGHPUT_MBPS[io2]=1000
MAX_THROUGHPUT_MBPS[st1]=500
MAX_THROUGHPUT_MBPS[sc1]=250

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

# Calculate period in seconds for IOPS calculation
START_EPOCH=$(date -u -d "$START_DATE 00:00:00" +%s)
END_EPOCH=$(date -u -d "$END_DATE 23:59:59" +%s)
ANALYSIS_PERIOD_SECONDS=$((END_EPOCH - START_EPOCH))

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq, bc)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
    exit 1
fi
log "✅ Dependencies met."

log "📊 EBS Volume Optimization Analysis (IOPS Threshold: ${UTIL_THRESHOLD}%)"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Volume ID","Current Type","Size GiB","Provisioned IOPS","Avg IOPS Used %%","Avg Throughput Used %%","Recommendation","Estimated Monthly Savings","Attached Instance","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all in-use EBS volumes (attached to instances)
    VOLUMES_DATA=$(aws ec2 describe-volumes --region "$region" \
        --filters "Name=status,Values=in-use" \
        --query 'Volumes[]' \
        --output json)

    VOLUME_COUNT=$(echo "$VOLUMES_DATA" | jq 'length')

    if [[ "$VOLUME_COUNT" -gt 0 ]]; then
        log "  Found $VOLUME_COUNT in-use volume(s) in $region"

        CURRENT_IDX=0
        echo "$VOLUMES_DATA" | jq -c '.[]' | while read -r volume; do
            CURRENT_IDX=$((CURRENT_IDX + 1))
            VOLUME_ID=$(echo "$volume" | jq -r '.VolumeId')
            VOLUME_TYPE=$(echo "$volume" | jq -r '.VolumeType')
            VOLUME_SIZE=$(echo "$volume" | jq -r '.Size')
            PROVISIONED_IOPS=$(echo "$volume" | jq -r '.Iops // 0')
            ATTACHED_INSTANCE=$(echo "$volume" | jq -r '.Attachments[0].InstanceId // "N/A"')

            log "  [$CURRENT_IDX/$VOLUME_COUNT] Analyzing: $VOLUME_ID ($VOLUME_TYPE, ${VOLUME_SIZE} GiB)"

            # --- Get CloudWatch Metrics ---

            # Get VolumeReadOps (Sum over period)
            READ_OPS=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EBS \
                --metric-name VolumeReadOps \
                --dimensions Name=VolumeId,Value="$VOLUME_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$ANALYSIS_PERIOD_SECONDS" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text 2>/dev/null) || true

            # Get VolumeWriteOps (Sum over period)
            WRITE_OPS=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EBS \
                --metric-name VolumeWriteOps \
                --dimensions Name=VolumeId,Value="$VOLUME_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$ANALYSIS_PERIOD_SECONDS" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text 2>/dev/null) || true

            # Get VolumeReadBytes (Sum over period)
            READ_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EBS \
                --metric-name VolumeReadBytes \
                --dimensions Name=VolumeId,Value="$VOLUME_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$ANALYSIS_PERIOD_SECONDS" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text 2>/dev/null) || true

            # Get VolumeWriteBytes (Sum over period)
            WRITE_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EBS \
                --metric-name VolumeWriteBytes \
                --dimensions Name=VolumeId,Value="$VOLUME_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$ANALYSIS_PERIOD_SECONDS" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text 2>/dev/null) || true

            # Handle null/None values
            READ_OPS=${READ_OPS:-"None"}
            WRITE_OPS=${WRITE_OPS:-"None"}
            READ_BYTES=${READ_BYTES:-"None"}
            WRITE_BYTES=${WRITE_BYTES:-"None"}

            if [ "$READ_OPS" = "null" ] || [ "$READ_OPS" = "None" ]; then READ_OPS=0; fi
            if [ "$WRITE_OPS" = "null" ] || [ "$WRITE_OPS" = "None" ]; then WRITE_OPS=0; fi
            if [ "$READ_BYTES" = "null" ] || [ "$READ_BYTES" = "None" ]; then READ_BYTES=0; fi
            if [ "$WRITE_BYTES" = "null" ] || [ "$WRITE_BYTES" = "None" ]; then WRITE_BYTES=0; fi

            # --- Calculate Average IOPS Used ---
            # Average IOPS = (ReadOps + WriteOps) / period_seconds
            AVG_IOPS=$(echo "($READ_OPS + $WRITE_OPS) / $ANALYSIS_PERIOD_SECONDS" | bc -l 2>/dev/null || echo "0")

            # --- Calculate IOPS Utilization % ---
            # For io1/io2: compare against provisioned IOPS
            # For gp2: baseline IOPS = max(100, 3 * volume_size), burst up to 3000
            # For gp3: baseline 3000 IOPS
            BASELINE_IOPS=0
            case "$VOLUME_TYPE" in
                gp2)
                    # gp2 baseline IOPS = max(100, 3 * volume_size)
                    GP2_CALC_IOPS=$((VOLUME_SIZE * 3))
                    if [ "$GP2_CALC_IOPS" -gt 100 ]; then
                        BASELINE_IOPS=$GP2_CALC_IOPS
                    else
                        BASELINE_IOPS=100
                    fi
                    ;;
                gp3)
                    BASELINE_IOPS=${PROVISIONED_IOPS:-3000}
                    if [ "$BASELINE_IOPS" -eq 0 ]; then BASELINE_IOPS=3000; fi
                    ;;
                io1|io2)
                    BASELINE_IOPS=$PROVISIONED_IOPS
                    ;;
                st1)
                    BASELINE_IOPS=500
                    ;;
                sc1)
                    BASELINE_IOPS=250
                    ;;
            esac

            if [ "$BASELINE_IOPS" -gt 0 ] 2>/dev/null; then
                AVG_IOPS_USED_PCT=$(echo "$AVG_IOPS / $BASELINE_IOPS * 100" | bc -l 2>/dev/null || echo "0")
            else
                AVG_IOPS_USED_PCT="0"
            fi

            # --- Calculate Average Throughput Used % ---
            # Average throughput = (ReadBytes + WriteBytes) / period_seconds (bytes/sec)
            AVG_THROUGHPUT_BPS=$(echo "($READ_BYTES + $WRITE_BYTES) / $ANALYSIS_PERIOD_SECONDS" | bc -l 2>/dev/null || echo "0")
            # Convert to MB/s
            AVG_THROUGHPUT_MBPS=$(echo "$AVG_THROUGHPUT_BPS / 1048576" | bc -l 2>/dev/null || echo "0")

            # Get max throughput for volume type
            MAX_TP=${MAX_THROUGHPUT_MBPS[$VOLUME_TYPE]:-250}
            if [ "$MAX_TP" != "0" ]; then
                AVG_THROUGHPUT_USED_PCT=$(echo "$AVG_THROUGHPUT_MBPS / $MAX_TP * 100" | bc -l 2>/dev/null || echo "0")
            else
                AVG_THROUGHPUT_USED_PCT="0"
            fi

            # --- Generate Recommendations ---
            RECOMMENDATION=""
            ESTIMATED_SAVINGS="0.00"

            case "$VOLUME_TYPE" in
                gp2)
                    # ALL gp2 volumes get a recommendation to migrate to gp3
                    GP2_PRICE=$(get_ebs_price "gp2_per_gb" "$region") || true
                    GP3_PRICE=$(get_ebs_price "gp3_per_gb" "$region") || true

                    if [ -n "$GP2_PRICE" ] && [ -n "$GP3_PRICE" ]; then
                        ESTIMATED_SAVINGS=$(echo "($GP2_PRICE - $GP3_PRICE) * $VOLUME_SIZE" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "0.00")
                        # Ensure non-negative
                        SAVINGS_NEGATIVE=$(echo "$ESTIMATED_SAVINGS < 0" | bc -l 2>/dev/null || echo "0")
                        if [ "$SAVINGS_NEGATIVE" = "1" ]; then ESTIMATED_SAVINGS="0.00"; fi
                    fi
                    RECOMMENDATION="Migrate to gp3"
                    log "    💰 gp2→gp3 migration savings: \$${ESTIMATED_SAVINGS}/month"
                    ;;

                io1|io2)
                    # Check if provisioned IOPS utilization is below threshold
                    IOPS_BELOW_THRESHOLD=$(echo "$AVG_IOPS_USED_PCT < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")

                    if [ "$IOPS_BELOW_THRESHOLD" = "1" ] && [ "$PROVISIONED_IOPS" -gt 0 ]; then
                        # Recommend reducing IOPS
                        # Recommended IOPS = max(3000, actual_avg_iops * 1.5) — give 50% headroom
                        RECOMMENDED_IOPS_RAW=$(echo "$AVG_IOPS * 1.5" | bc -l 2>/dev/null | xargs printf "%.0f" || echo "3000")
                        if [ "$RECOMMENDED_IOPS_RAW" -lt 3000 ]; then
                            RECOMMENDED_IOPS=3000
                        else
                            RECOMMENDED_IOPS=$RECOMMENDED_IOPS_RAW
                        fi

                        # Calculate savings from IOPS reduction
                        IOPS_PRICE=$(get_ebs_price "${VOLUME_TYPE}_per_iops" "$region") || true
                        if [ -n "$IOPS_PRICE" ]; then
                            IOPS_REDUCTION=$((PROVISIONED_IOPS - RECOMMENDED_IOPS))
                            if [ "$IOPS_REDUCTION" -gt 0 ]; then
                                ESTIMATED_SAVINGS=$(echo "$IOPS_REDUCTION * $IOPS_PRICE" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "0.00")
                            fi
                        fi

                        RECOMMENDATION="Reduce provisioned IOPS to ${RECOMMENDED_IOPS}"
                        log "    💰 IOPS reduction savings: \$${ESTIMATED_SAVINGS}/month (${PROVISIONED_IOPS} → ${RECOMMENDED_IOPS} IOPS)"
                    else
                        # io1/io2 volume is adequately utilized
                        RECOMMENDATION="N/A"
                        ESTIMATED_SAVINGS="0.00"
                    fi
                    ;;

                *)
                    # For other volume types (gp3, st1, sc1), check general underutilization
                    IOPS_BELOW=$(echo "$AVG_IOPS_USED_PCT < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")
                    TP_BELOW=$(echo "$AVG_THROUGHPUT_USED_PCT < $UTIL_THRESHOLD" | bc -l 2>/dev/null || echo "0")

                    if [ "$IOPS_BELOW" = "1" ] && [ "$TP_BELOW" = "1" ]; then
                        RECOMMENDATION="Underutilized - review sizing"
                    else
                        RECOMMENDATION="N/A"
                    fi
                    ESTIMATED_SAVINGS="0.00"
                    ;;
            esac

            # Format percentage values for output
            AVG_IOPS_USED_PCT_FMT=$(printf "%.2f" "$AVG_IOPS_USED_PCT" 2>/dev/null || echo "0.00")
            AVG_THROUGHPUT_USED_PCT_FMT=$(printf "%.2f" "$AVG_THROUGHPUT_USED_PCT" 2>/dev/null || echo "0.00")

            # Only output rows that have a recommendation (skip N/A)
            if [ "$RECOMMENDATION" != "N/A" ]; then
                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$VOLUME_ID" \
                    "$VOLUME_TYPE" \
                    "$VOLUME_SIZE" \
                    "$PROVISIONED_IOPS" \
                    "$AVG_IOPS_USED_PCT_FMT" \
                    "$AVG_THROUGHPUT_USED_PCT_FMT" \
                    "$RECOMMENDATION" \
                    "$ESTIMATED_SAVINGS" \
                    "$ATTACHED_INSTANCE" \
                    "$region" >> "$OUTPUT_FILE"
            fi
        done
    else
        log "  [EBS] No in-use volumes found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. EBS Optimization report saved to: $OUTPUT_FILE"

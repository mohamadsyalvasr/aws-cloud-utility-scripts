#!/bin/bash
# data_transfer_optimization_report.sh
# Identifies high data transfer costs and provides optimization recommendations
# by analyzing Cost Explorer data, NAT Gateway usage, and cross-region transfer patterns.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/data_transfer_optimization_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
DATA_TRANSFER_ALERT_THRESHOLD="${DATA_TRANSFER_ALERT_THRESHOLD:-100}"

# Source pricing helper for consistency
source ./lib/pricing_helper.sh

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for analysis (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for analysis (YYYY-MM-DD).
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
log "🔎 Checking dependencies (aws cli, jq)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."
    exit 1
fi
log "✅ Dependencies met."

log "📊 Data Transfer Optimization Analysis (Threshold: \$${DATA_TRANSFER_ALERT_THRESHOLD}/month)"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Resource Type","Resource ID","Transfer Type","Monthly Data Volume GB","Monthly Cost","Recommendation","Estimated Monthly Savings","Region"\n' > "$OUTPUT_FILE"

# NAT Gateway processing cost per GB
NAT_GW_COST_PER_GB=0.045

# --- Cost Explorer: Data Transfer Breakdown ---
log "📡 Retrieving data transfer cost breakdown from Cost Explorer..."

CE_ACCESS_DENIED=false

set +e
CE_RESULT=$(aws ce get-cost-and-usage \
    --time-period Start="$START_DATE",End="$END_DATE" \
    --granularity MONTHLY \
    --filter '{
        "Or": [
            {"Dimensions": {"Key": "USAGE_TYPE", "MatchOption": "CONTAINS", "Values": ["DataTransfer"]}},
            {"Dimensions": {"Key": "USAGE_TYPE", "MatchOption": "CONTAINS", "Values": ["NatGateway"]}}
        ]
    }' \
    --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=USAGE_TYPE \
    --output json 2>&1)
CE_EXIT_CODE=$?
set -e

if [ $CE_EXIT_CODE -ne 0 ]; then
    if echo "$CE_RESULT" | grep -qi "AccessDenied\|not authorized\|access denied"; then
        log "⚠️ Cost Explorer AccessDenied: Unable to retrieve data transfer costs. Continuing with other checks."
        CE_ACCESS_DENIED=true
    else
        log "⚠️ Cost Explorer error: $CE_RESULT. Continuing with other checks."
        CE_ACCESS_DENIED=true
    fi
fi

# Process Cost Explorer results for cross-region transfers
if [ "$CE_ACCESS_DENIED" = false ] && [ -n "$CE_RESULT" ]; then
    log "  Processing Cost Explorer data transfer results..."

    # Extract cross-region transfer entries
    CROSS_REGION_DATA=$(echo "$CE_RESULT" | jq -r '
        .ResultsByTime[].Groups[] |
        select(.Keys[1] | test("InterRegion"; "i")) |
        {service: .Keys[0], usage_type: .Keys[1], cost: (.Metrics.UnblendedCost.Amount | tonumber)}
    ' 2>/dev/null || echo "")

    if [ -n "$CROSS_REGION_DATA" ]; then
        echo "$CROSS_REGION_DATA" | jq -c '.' 2>/dev/null | while read -r entry; do
            SERVICE=$(echo "$entry" | jq -r '.service')
            USAGE_TYPE=$(echo "$entry" | jq -r '.usage_type')
            MONTHLY_COST=$(echo "$entry" | jq -r '.cost')

            # Skip if cost is below threshold
            EXCEEDS_THRESHOLD=$(echo "$MONTHLY_COST > $DATA_TRANSFER_ALERT_THRESHOLD" | bc -l 2>/dev/null || echo "0")
            if [ "$EXCEEDS_THRESHOLD" != "1" ]; then
                continue
            fi

            # Estimate data volume from cost (approximate $0.02/GB for cross-region)
            DATA_VOLUME_GB=$(echo "$MONTHLY_COST / 0.02" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "N/A")

            # Determine recommendation based on usage type
            RECOMMENDATION="Consolidate resources to single region"
            if echo "$USAGE_TYPE" | grep -qi "CloudFront\|CDN"; then
                RECOMMENDATION="Use CloudFront for distribution"
            fi

            # Estimated savings: 30-50% reduction through consolidation
            ESTIMATED_SAVINGS=$(echo "$MONTHLY_COST * 0.40" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "N/A")

            MONTHLY_COST_FMT=$(printf "%.2f" "$MONTHLY_COST")

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "Cross-Region Transfer" \
                "$SERVICE" \
                "Cross-Region ($USAGE_TYPE)" \
                "$DATA_VOLUME_GB" \
                "$MONTHLY_COST_FMT" \
                "$RECOMMENDATION" \
                "$ESTIMATED_SAVINGS" \
                "Multiple" >> "$OUTPUT_FILE"

            log "    💰 Cross-region transfer: $SERVICE - \$${MONTHLY_COST_FMT}/month"
        done
    fi

    # Extract general data transfer entries (non-cross-region)
    GENERAL_DT_DATA=$(echo "$CE_RESULT" | jq -r '
        .ResultsByTime[].Groups[] |
        select(.Keys[1] | test("InterRegion"; "i") | not) |
        select(.Keys[1] | test("DataTransfer"; "i")) |
        {service: .Keys[0], usage_type: .Keys[1], cost: (.Metrics.UnblendedCost.Amount | tonumber)}
    ' 2>/dev/null || echo "")

    if [ -n "$GENERAL_DT_DATA" ]; then
        echo "$GENERAL_DT_DATA" | jq -c '.' 2>/dev/null | while read -r entry; do
            SERVICE=$(echo "$entry" | jq -r '.service')
            USAGE_TYPE=$(echo "$entry" | jq -r '.usage_type')
            MONTHLY_COST=$(echo "$entry" | jq -r '.cost')

            # Skip if cost is below threshold
            EXCEEDS_THRESHOLD=$(echo "$MONTHLY_COST > $DATA_TRANSFER_ALERT_THRESHOLD" | bc -l 2>/dev/null || echo "0")
            if [ "$EXCEEDS_THRESHOLD" != "1" ]; then
                continue
            fi

            # Estimate data volume (approximate $0.09/GB for internet out)
            DATA_VOLUME_GB=$(echo "$MONTHLY_COST / 0.09" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "N/A")

            RECOMMENDATION="Use CloudFront for distribution"
            ESTIMATED_SAVINGS=$(echo "$MONTHLY_COST * 0.30" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "N/A")

            MONTHLY_COST_FMT=$(printf "%.2f" "$MONTHLY_COST")

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "Data Transfer" \
                "$SERVICE" \
                "Internet Out ($USAGE_TYPE)" \
                "$DATA_VOLUME_GB" \
                "$MONTHLY_COST_FMT" \
                "$RECOMMENDATION" \
                "$ESTIMATED_SAVINGS" \
                "Multiple" >> "$OUTPUT_FILE"

            log "    💰 Data transfer: $SERVICE - \$${MONTHLY_COST_FMT}/month"
        done
    fi
fi

# --- NAT Gateway Analysis ---
log "📡 Analyzing NAT Gateway data processing volumes..."

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all available NAT Gateways
    set +e
    NAT_GW_DATA=$(aws ec2 describe-nat-gateways --region "$region" \
        --filter "Name=state,Values=available" \
        --query 'NatGateways[]' \
        --output json 2>&1)
    NAT_GW_EXIT=$?
    set -e

    if [ $NAT_GW_EXIT -ne 0 ]; then
        log "  ⚠️ Unable to describe NAT Gateways in $region: $NAT_GW_DATA"
        continue
    fi

    NAT_GW_COUNT=$(echo "$NAT_GW_DATA" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$NAT_GW_COUNT" -gt 0 ]]; then
        log "  Found $NAT_GW_COUNT NAT Gateway(s) in $region"

        echo "$NAT_GW_DATA" | jq -c '.[]' | while read -r natgw; do
            NAT_GW_ID=$(echo "$natgw" | jq -r '.NatGatewayId')
            NAT_GW_NAME=$(echo "$natgw" | jq -r '(.Tags // [])[] | select(.Key == "Name") | .Value // "N/A"')
            NAT_GW_NAME="${NAT_GW_NAME:-$NAT_GW_ID}"

            log "  Analyzing NAT Gateway: $NAT_GW_ID"

            # Get BytesOutToDestination from CloudWatch (data processed outbound)
            START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
            END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)
            PERIOD=2592000 # 30 days in seconds

            BYTES_OUT_DEST=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/NATGateway \
                --metric-name BytesOutToDestination \
                --dimensions Name=NatGatewayId,Value="$NAT_GW_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "sort_by(Datapoints, &Timestamp)[-1].Sum" \
                --output text 2>/dev/null || echo "None")

            BYTES_OUT_SRC=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/NATGateway \
                --metric-name BytesOutToSource \
                --dimensions Name=NatGatewayId,Value="$NAT_GW_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "sort_by(Datapoints, &Timestamp)[-1].Sum" \
                --output text 2>/dev/null || echo "None")

            # Handle null/None values
            if [ "$BYTES_OUT_DEST" = "None" ] || [ "$BYTES_OUT_DEST" = "null" ] || [ -z "$BYTES_OUT_DEST" ]; then
                BYTES_OUT_DEST=0
            fi
            if [ "$BYTES_OUT_SRC" = "None" ] || [ "$BYTES_OUT_SRC" = "null" ] || [ -z "$BYTES_OUT_SRC" ]; then
                BYTES_OUT_SRC=0
            fi

            # Calculate total bytes processed and convert to GB
            TOTAL_BYTES=$(echo "$BYTES_OUT_DEST + $BYTES_OUT_SRC" | bc -l 2>/dev/null || echo "0")
            DATA_VOLUME_GB=$(echo "$TOTAL_BYTES / 1073741824" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "0.00")

            # Calculate monthly cost based on NAT Gateway processing rate
            MONTHLY_COST=$(echo "$DATA_VOLUME_GB * $NAT_GW_COST_PER_GB" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "0.00")

            # Check if cost exceeds threshold
            EXCEEDS_THRESHOLD=$(echo "$MONTHLY_COST > $DATA_TRANSFER_ALERT_THRESHOLD" | bc -l 2>/dev/null || echo "0")

            if [ "$EXCEEDS_THRESHOLD" = "1" ]; then
                # Determine recommendation
                # If high volume, recommend VPC endpoints for S3/DynamoDB or VPC peering
                if echo "$DATA_VOLUME_GB" | awk '{exit ($1 > 1000) ? 0 : 1}' 2>/dev/null; then
                    RECOMMENDATION="Use VPC endpoints for S3/DynamoDB"
                    # VPC endpoints eliminate NAT Gateway charges for S3/DynamoDB traffic
                    # Estimate ~60% of NAT traffic is to S3/DynamoDB
                    ESTIMATED_SAVINGS=$(echo "$MONTHLY_COST * 0.60" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "N/A")
                else
                    RECOMMENDATION="Consider VPC peering"
                    # VPC peering can reduce inter-VPC traffic through NAT
                    ESTIMATED_SAVINGS=$(echo "$MONTHLY_COST * 0.40" | bc -l 2>/dev/null | xargs printf "%.2f" || echo "N/A")
                fi

                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "NAT Gateway" \
                    "$NAT_GW_ID" \
                    "NAT Gateway Processing" \
                    "$DATA_VOLUME_GB" \
                    "$MONTHLY_COST" \
                    "$RECOMMENDATION" \
                    "$ESTIMATED_SAVINGS" \
                    "$region" >> "$OUTPUT_FILE"

                log "    💰 NAT Gateway $NAT_GW_ID: ${DATA_VOLUME_GB} GB processed, \$${MONTHLY_COST}/month"
            else
                log "    ℹ️ NAT Gateway $NAT_GW_ID: \$${MONTHLY_COST}/month (below threshold)"
            fi
        done
    else
        log "  [NAT Gateway] No available NAT Gateways found in $region."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Data Transfer Optimization report saved to: $OUTPUT_FILE"

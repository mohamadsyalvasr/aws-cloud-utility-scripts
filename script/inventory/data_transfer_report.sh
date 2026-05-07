#!/bin/bash
# data_transfer_report.sh
# Gathers a report on AWS Data Transfer usage and costs.
# Part 1: Cost breakdown by service from Cost Explorer (global).
# Part 2: Network In/Out per EC2 instance from CloudWatch (per region).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_COST="${OUTPUT_DIR}/data_transfer_cost_report.csv"
OUTPUT_FILE_INSTANCE="${OUTPUT_DIR}/data_transfer_instance_report.csv"
START_DATE=""
END_DATE=""
PERIOD=2592000 # ~30 days in seconds

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-r regions] [-h]

Options:
  -b <start_date>  REQUIRED: Start date (YYYY-MM-DD).
  -e <end_date>    REQUIRED: End date (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions.
                   Default: ${REGIONS[*]}
  -h               Show this help message.

This script generates two CSV files:
  1. data_transfer_cost_report.csv   - Cost breakdown from Cost Explorer
  2. data_transfer_instance_report.csv - Network bytes per EC2 instance
EOF
    exit 1
}

while getopts "b:e:r:h" opt; do
    case "$opt" in
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq, bc)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found."; exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found."; exit 1
    fi
    if ! command -v bc >/dev/null 2>&1; then
        log "❌ bc not found."; exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
mkdir -p "$(dirname "$OUTPUT_FILE_COST")"

# =========================================================================
# PART 1: Data Transfer Cost from Cost Explorer (Global)
# =========================================================================
log "✍️ [Part 1] Generating data transfer cost report..."
printf '"Service","Usage Type","Cost (USD)","Unit","Period"\n' > "$OUTPUT_FILE_COST"

# Get cost and usage filtered by data transfer usage types
COST_DATA=$(aws ce get-cost-and-usage \
    --time-period Start="$START_DATE",End="$END_DATE" \
    --metrics "BlendedCost" "UsageQuantity" \
    --granularity "MONTHLY" \
    --filter '{
        "Dimensions": {
            "Key": "USAGE_TYPE_GROUP",
            "Values": [
                "EC2: Data Transfer - Internet (Out)",
                "EC2: Data Transfer - Internet (In)",
                "EC2: Data Transfer - Region to Region (Out)",
                "EC2: Data Transfer - Region to Region (In)",
                "EC2: Data Transfer - Inter AZ",
                "EC2: Data Transfer - CloudFront (Out)",
                "EC2: Data Transfer - CloudFront (In)",
                "RDS: Data Transfer - Internet (Out)",
                "RDS: Data Transfer - Internet (In)",
                "RDS: Data Transfer - Inter AZ",
                "S3: Data Transfer - Internet (Out)",
                "S3: Data Transfer - Internet (In)",
                "CloudFront: Data Transfer - Internet (Out)",
                "ElastiCache: Data Transfer - Internet (Out)",
                "ElastiCache: Data Transfer - Inter AZ"
            ]
        }
    }' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json 2>/dev/null || echo '{"ResultsByTime":[]}')

# Parse results
RESULTS_COUNT=$(echo "$COST_DATA" | jq '.ResultsByTime | length')

if [[ "$RESULTS_COUNT" -gt 0 ]]; then
    echo "$COST_DATA" | jq -r --arg period "${START_DATE} to ${END_DATE}" '
        .ResultsByTime[].Groups[] |
        [
            (.Keys[0] // "N/A"),
            (.Keys[0] // "N/A"),
            (.Metrics.BlendedCost.Amount // "0"),
            (.Metrics.BlendedCost.Unit // "USD"),
            $period
        ] | @csv
    ' >> "$OUTPUT_FILE_COST"
    log "  ✅ Cost data written."
else
    log "  ⚠️ No data transfer cost data found. Trying alternative approach..."
    
    # Fallback: get all costs grouped by usage type, filter for transfer-related
    COST_DATA_ALL=$(aws ce get-cost-and-usage \
        --time-period Start="$START_DATE",End="$END_DATE" \
        --metrics "BlendedCost" \
        --granularity "MONTHLY" \
        --group-by Type=DIMENSION,Key=USAGE_TYPE \
        --output json 2>/dev/null || echo '{"ResultsByTime":[]}')
    
    # Filter for data transfer related usage types
    echo "$COST_DATA_ALL" | jq -r --arg period "${START_DATE} to ${END_DATE}" '
        .ResultsByTime[].Groups[] |
        select(.Keys[0] | test("DataTransfer|Bytes|Transfer|CloudFront-Out"; "i")) |
        [
            (.Keys[0] // "N/A"),
            (.Keys[0] // "N/A"),
            (.Metrics.BlendedCost.Amount // "0"),
            (.Metrics.BlendedCost.Unit // "USD"),
            $period
        ] | @csv
    ' >> "$OUTPUT_FILE_COST" 2>/dev/null || true
    
    log "  ✅ Fallback cost data written."
fi

log "✅ [Part 1] Cost report saved to: $OUTPUT_FILE_COST"

# =========================================================================
# PART 2: Network In/Out per EC2 Instance from CloudWatch (Per Region)
# =========================================================================
log "✍️ [Part 2] Generating per-instance data transfer report..."
printf '"Instance Name","Instance ID","Instance Type","Network In (GB)","Network Out (GB)","Total Transfer (GB)","Region"\n' > "$OUTPUT_FILE_INSTANCE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get running EC2 instances
    EC2_DATA=$(aws ec2 describe-instances --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId, InstanceType, Tags[?Key==`Name`].Value | [0]]' \
        --output json)

    if [[ "$(echo "$EC2_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [EC2] No running instances found."
        log "Region \033[1;33m$region\033[0m Complete."
        continue
    fi

    INSTANCE_COUNT=$(echo "$EC2_DATA" | jq 'length')
    log "  [EC2] Found $INSTANCE_COUNT running instances. Fetching network metrics..."

    echo "$EC2_DATA" | jq -c '.[]' | while read -r instance; do
        INSTANCE_ID=$(echo "$instance" | jq -r '.[0]')
        INSTANCE_TYPE=$(echo "$instance" | jq -r '.[1]')
        INSTANCE_NAME=$(echo "$instance" | jq -r '.[2] // "N/A"')

        # Get NetworkIn (bytes received) - Sum over period
        NETWORK_IN_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
            --namespace AWS/EC2 \
            --metric-name NetworkIn \
            --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
            --start-time "$START_TIME" \
            --end-time "$END_TIME" \
            --period "$PERIOD" \
            --statistics Sum \
            --query "sort_by(Datapoints, &Timestamp)[-1].Sum" \
            --output text)

        # Get NetworkOut (bytes sent) - Sum over period
        NETWORK_OUT_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
            --namespace AWS/EC2 \
            --metric-name NetworkOut \
            --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
            --start-time "$START_TIME" \
            --end-time "$END_TIME" \
            --period "$PERIOD" \
            --statistics Sum \
            --query "sort_by(Datapoints, &Timestamp)[-1].Sum" \
            --output text)

        # Handle None/null values
        if [[ -z "$NETWORK_IN_BYTES" || "$NETWORK_IN_BYTES" == "None" || "$NETWORK_IN_BYTES" == "null" ]]; then
            NETWORK_IN_BYTES=0
        fi
        if [[ -z "$NETWORK_OUT_BYTES" || "$NETWORK_OUT_BYTES" == "None" || "$NETWORK_OUT_BYTES" == "null" ]]; then
            NETWORK_OUT_BYTES=0
        fi

        # Convert bytes to GB
        NETWORK_IN_GB=$(echo "scale=2; $NETWORK_IN_BYTES / 1073741824" | bc)
        NETWORK_OUT_GB=$(echo "scale=2; $NETWORK_OUT_BYTES / 1073741824" | bc)
        TOTAL_TRANSFER_GB=$(echo "scale=2; $NETWORK_IN_GB + $NETWORK_OUT_GB" | bc)

        printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
            "$INSTANCE_NAME" \
            "$INSTANCE_ID" \
            "$INSTANCE_TYPE" \
            "$NETWORK_IN_GB" \
            "$NETWORK_OUT_GB" \
            "$TOTAL_TRANSFER_GB" \
            "$region" >> "$OUTPUT_FILE_INSTANCE"
    done

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ [Part 2] Instance report saved to: $OUTPUT_FILE_INSTANCE"
log "✅ DONE. Data Transfer reports generated."

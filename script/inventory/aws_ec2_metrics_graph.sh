#!/bin/bash
# aws_ec2_metrics_graph.sh
# Fetches time-series CloudWatch metrics (CPU, Memory) for EC2 instances
# and outputs them as a single JSON file for plotting.

set -euo pipefail

log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
# TS=$(date +"%Y%m%d-%H%M%S")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-$(date +%Y-%m-%d)}/metrics"
FILENAME="${OUTPUT_DIR}/aws_ec2_metrics_data.json"
START_DATE=""
END_DATE=""
PERIOD=3600 # 1 hour in seconds for time series data

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for metrics. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for metrics. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions.
                   Default: ${REGIONS[*]}
  -f <filename>    Name of the output JSON file.
                   Default: aws_ec2_metrics_data_<timestamp>.json
  -h               Show this help message.
EOF
    exit 1
}

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
            FILENAME="$OPTARG"
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

# Function to fetch and format metric data as flat JSON objects
fetch_metric_data() {
    local ID="$1"
    local RESOURCE_TYPE="$2"
    local REGION="$3"
    local NAMESPACE="$4"
    local METRIC_NAME="$5"
    local DIMENSION_NAME="$6"
    local INSTANCE_NAME="$7"

    # Call CloudWatch to get time-series data points (Average over each period)
    METRIC_DATA=$(aws cloudwatch get-metric-statistics \
        --region "$REGION" \
        --namespace "$NAMESPACE" \
        --metric-name "$METRIC_NAME" \
        --dimensions Name="$DIMENSION_NAME",Value="$ID" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period "$PERIOD" \
        --statistics Average \
        --query "Datapoints[*].{Timestamp:Timestamp, Value:Average}" \
        --output json)

    # Use jq to format each datapoint into a uniform JSON object.
    if [[ "$(echo "$METRIC_DATA" | jq 'length')" -gt 0 ]]; then
        echo "$METRIC_DATA" | jq -c --arg id "$ID" \
                                   --arg resource "$RESOURCE_TYPE" \
                                   --arg metric "$METRIC_NAME" \
                                   --arg region "$REGION" \
                                   --arg name "$INSTANCE_NAME" \
                                   '.[] | {id: $id, name: $name, resource: $resource, region: $region, metric: $metric, timestamp: .Timestamp, value: .Value}'
    fi
}

# --- Main Script ---
check_dependencies
mkdir -p "$OUTPUT_DIR"
log "✍️ Preparing output file for EC2: $FILENAME"

# Initialize JSON array
echo "[" > "$FILENAME"
FIRST_ENTRY=true

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- PROCESS EC2 ---
    log "  [EC2] Fetching EC2 instance data..."
    # Fetch running EC2 instances along with their Name tag
    EC2_DATA=$(aws ec2 describe-instances --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].{ID:InstanceId, Name:Tags[?Key==`Name`].Value | [0]}' --output json)

    log "  [EC2] Fetching metrics for EC2 instances..."
    while IFS= read -r instance; do
        ID=$(echo "$instance" | jq -r '.ID')
        NAME=$(echo "$instance" | jq -r '.Name')
        NAME=${NAME:-"N/A"}
        
        # 1. CPU Utilization (AWS/EC2)
        CPU_METRICS=$(fetch_metric_data "$ID" "EC2" "$region" "AWS/EC2" "CPUUtilization" "InstanceId" "$NAME")
        if [ -n "$CPU_METRICS" ]; then
            if [ "$FIRST_ENTRY" = false ]; then echo "," >> "$FILENAME"; fi
            echo "$CPU_METRICS" | tr '\n' ' ' | sed 's/}, /},/g' >> "$FILENAME"
            FIRST_ENTRY=false
        fi

        # 2. Memory Utilization (CWAgent - Requires CloudWatch Agent installed)
        MEM_METRICS=$(fetch_metric_data "$ID" "EC2" "$region" "CWAgent" "MemoryUtilization" "InstanceId" "$NAME")
        if [ -n "$MEM_METRICS" ]; then
            if [ "$FIRST_ENTRY" = false ]; then echo "," >> "$FILENAME"; fi
            echo "$MEM_METRICS" | tr '\n' ' ' | sed 's/}, /},/g' >> "$FILENAME"
            FIRST_ENTRY=false
        fi

    done < <(echo "$EC2_DATA" | jq -c '.[]')
    
    log "Region \033[1;33m$region\033[0m Complete."
done

# Finalize JSON array
echo "]" >> "$FILENAME"

log "✅ DONE. EC2 time series metrics data saved to: $FILENAME"
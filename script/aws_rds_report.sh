#!/bin/bash
# aws_rds_report.sh
# Gathers a detailed report on RDS instances, including specifications and average utilization metrics.

set -euo pipefail

log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
# TS=$(date +"%Y%m%d-%H%M%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
FILENAME="${OUTPUT_DIR}/aws_rds_report.csv"
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Name of the output CSV file.
                   Default: aws_rds_report_<timestamp>.csv
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

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $FILENAME"

# Create CSV header (UPDATED to include Used Disk, Read Latency, Write Latency)
printf '"Name","Instance ID","Instance state","Type","Engine","Instance type","Elastic IP","Launch time","vCPUs","Memory (GiB)","Disk (GiB)","Used Disk (GiB)","Average CPU %%","Average Memory %%","Average Read Latency (s)","Average Write Latency (s)","Region"\n' > "$FILENAME"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- PROCESS RDS ---
    log "  [RDS] Fetching DB instance data..."
    RDS_DATA=$(aws rds describe-db-instances --region "$region" --query 'DBInstances[]' --output json)

    if [[ "$(echo "$RDS_DATA" | jq 'length')" -gt 0 ]]; then
        declare -A RDS_SPECS_CACHE
        mapfile -t UNIQUE_ENGINES < <(echo "$RDS_DATA" | jq -r '.[].Engine' | sort -u)
        
        log "  [RDS] Caching specs for engines: ${UNIQUE_ENGINES[*]}..."
        for engine in "${UNIQUE_ENGINES[@]}"; do
            CLASS_SPECS=$(aws rds describe-orderable-db-instance-options --region "$region" --engine "$engine" --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass, Vcpu:Vcpu, Mem:Memory}' --output json 2>/dev/null || echo "[]")
            while IFS= read -r spec; do
                class=$(echo "$spec" | jq -r '.Class')
                vcpu=$(echo "$spec" | jq -r '.Vcpu')
                mem_gib=$(echo "$spec" | jq -r '.Mem')

                if [[ "$class" == "null" ]]; then continue; fi
                if [[ "$vcpu" == "null" ]]; then vcpu="N/A"; fi
                if [[ "$mem_gib" == "null" ]]; then mem_gib="N/A"; fi

                CACHE_KEY="$class,$engine"
                RDS_SPECS_CACHE["$CACHE_KEY"]="$vcpu,$mem_gib"
            done < <(echo "$CLASS_SPECS" | jq -c '.[]')
        done

        log "  [RDS] Processing and writing to CSV..."
        while IFS= read -r db_instance; do
            ID=$(echo "$db_instance" | jq -r '.DBInstanceIdentifier')
            STATE=$(echo "$db_instance" | jq -r '.DBInstanceStatus')
            CLASS=$(echo "$db_instance" | jq -r '.DBInstanceClass')
            ENGINE=$(echo "$db_instance" | jq -r '.Engine')
            CREATE_TIME=$(echo "$db_instance" | jq -r '.InstanceCreateTime')
            DISK_GIB=$(echo "$db_instance" | jq -r '.AllocatedStorage')
            DB_ARN=$(echo "$db_instance" | jq -r '.DBInstanceArn')
            
            NAME=$(aws rds list-tags-for-resource --resource-name "$DB_ARN" --region "$region" --query 'TagList[?Key==`Name`].Value' --output text | tr -d '\n' || echo "N/A")
            NAME=${NAME:-"N/A"}

            CACHE_KEY_TO_FIND="$CLASS,$ENGINE"
            SPECS=${RDS_SPECS_CACHE[$CACHE_KEY_TO_FIND]:="N/A,N/A"}
            VCPU=$(echo "$SPECS" | cut -d',' -f1)
            MEM_GIB=$(echo "$SPECS" | cut -d',' -f2)

            # --- CloudWatch Metrics ---

            CPU_UTIL=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name CPUUtilization \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            FREE_MEM=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name FreeableMemory \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)
            
            # New: Average Read Latency (s)
            READ_LATENCY=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name ReadLatency \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            # New: Average Write Latency (s)
            WRITE_LATENCY=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name WriteLatency \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)
            
            # New: Free Storage Space (in Bytes)
            FREE_STORAGE_BYTES=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name FreeStorageSpace \
                --dimensions Name=DBInstanceIdentifier,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            # --- Calculations ---
            
            # 1. Average Memory Utilization (%)
            if [[ -n "$MEM_GIB" && "$MEM_GIB" != "N/A" ]]; then
                TOTAL_MEMORY_BYTES=$(echo "scale=0; $MEM_GIB * 1073741824" | bc)
                AVG_MEMORY_PERCENT=$(echo "scale=2; (1 - (${FREE_MEM:-0} / ${TOTAL_MEMORY_BYTES:-1})) * 100" | bc)
            else
                AVG_MEMORY_PERCENT="N/A"
            fi
            
            # 2. Used Disk Capacity (GiB)
            # AllocatedStorage is in GiB. FreeStorageSpace is in Bytes.
            if [[ -n "$FREE_STORAGE_BYTES" && "$FREE_STORAGE_BYTES" != "null" ]]; then
                # Convert FreeStorageSpace (Bytes) to GiB
                FREE_STORAGE_GIB=$(echo "scale=2; $FREE_STORAGE_BYTES / 1073741824" | bc)
                # Calculate Used Disk (GiB) = Allocated - Free
                USED_DISK_GIB=$(echo "scale=2; $DISK_GIB - $FREE_STORAGE_GIB" | bc)
                # Prevent negative output due to potential data inconsistency or precision issues
                if (( $(echo "$USED_DISK_GIB < 0" | bc -l) )); then
                    USED_DISK_GIB=0
                fi
            else
                USED_DISK_GIB="N/A"
            fi
            
            # --- Print to CSV (UPDATED to include new metrics) ---

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$ID" \
                "$STATE" \
                "RDS" \
                "$ENGINE" \
                "$CLASS" \
                "N/A" \
                "$CREATE_TIME" \
                "$VCPU" \
                "$MEM_GIB" \
                "$DISK_GIB" \
                "${USED_DISK_GIB:-N/A}" \
                "${CPU_UTIL:-N/A}" \
                "${AVG_MEMORY_PERCENT:-N/A}" \
                "${READ_LATENCY:-N/A}" \
                "${WRITE_LATENCY:-N/A}" \
                "$region" >> "$FILENAME"
        done < <(echo "$RDS_DATA" | jq -c '.[]')
    else
        log "  [RDS] No DB instances found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Results saved to: $FILENAME"
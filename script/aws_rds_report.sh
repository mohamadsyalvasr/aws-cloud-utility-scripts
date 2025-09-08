#!/bin/bash
# aws_rds_report.sh
# Gathers a detailed report on RDS instances, including specifications and average utilization metrics.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
TS=$(date +"%Y%m%d-%H%M%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
FILENAME="${OUTPUT_DIR}/aws_rds_report_${TS}.csv"
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-r regions] [-f filename] [-h]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Name of the output CSV file.
                   Default: aws_rds_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq, bc)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script Logic ---
main() {
    check_dependencies
    
    while getopts "b:e:r:f:h" opt; do
        case "$opt" in
            b) START_DATE="$OPTARG" ;;
            e) END_DATE="$OPTARG" ;;
            r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
            f) FILENAME="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
    shift $((OPTIND-1))

    if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
        log "❌ Arguments -b and -e are required."
        usage
    fi

    local start_time=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ")
    local end_time=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ")

    log "✍️ Preparing output file: $FILENAME"
    printf '"Name","Instance ID","Instance state","Type","Engine","Instance type","Elastic IP","Launch time","vCPUs","Memory (GiB)","Disk (GiB)","Average CPU %%","Average Memory %%","Region"\n' > "$FILENAME"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local rds_data=$(aws rds describe-db-instances --region "$region" --query 'DBInstances[]' --output json)

        if [[ "$(echo "$rds_data" | jq 'length')" -gt 0 ]]; then
            declare -A rds_specs_cache
            mapfile -t unique_engines < <(echo "$rds_data" | jq -r '.[].Engine' | sort -u)
            
            log "  [RDS] Caching specs for engines: ${unique_engines[*]}..."
            for engine in "${unique_engines[@]}"; do
                local class_specs=$(aws rds describe-orderable-db-instance-options --region "$region" --engine "$engine" --query 'OrderableDBInstanceOptions[].{Class:DBInstanceClass, Vcpu:Vcpu, Mem:Memory}' --output json 2>/dev/null || echo "[]")
                while IFS= read -r spec; do
                    local class=$(echo "$spec" | jq -r '.Class')
                    local vcpu=$(echo "$spec" | jq -r '.Vcpu')
                    local mem_gib=$(echo "$spec" | jq -r '.Mem')

                    if [[ "$class" == "null" ]]; then continue; fi
                    if [[ "$vcpu" == "null" ]]; then vcpu="N/A"; fi
                    if [[ "$mem_gib" == "null" ]]; then mem_gib="N/A"; fi

                    local cache_key="$class,$engine"
                    rds_specs_cache["$cache_key"]="$vcpu,$mem_gib"
                done < <(echo "$class_specs" | jq -c '.[]')
            done

            log "  [RDS] Processing and writing to CSV..."
            while IFS= read -r db_instance; do
                local id=$(echo "$db_instance" | jq -r '.DBInstanceIdentifier')
                local state=$(echo "$db_instance" | jq -r '.DBInstanceStatus')
                local class=$(echo "$db_instance" | jq -r '.DBInstanceClass')
                local engine=$(echo "$db_instance" | jq -r '.Engine')
                local create_time=$(echo "$db_instance" | jq -r '.InstanceCreateTime')
                local disk_gib=$(echo "$db_instance" | jq -r '.AllocatedStorage')
                local db_arn=$(echo "$db_instance" | jq -r '.DBInstanceArn')
                
                local name=$(aws rds list-tags-for-resource --resource-name "$db_arn" --region "$region" --query 'TagList[?Key==`Name`].Value' --output text | tr -d '\n' || echo "N/A")
                name=${name:-"N/A"}

                local cache_key_to_find="$class,$engine"
                local specs=${rds_specs_cache[$cache_key_to_find]:="N/A,N/A"}
                local vcpu=$(echo "$specs" | cut -d',' -f1)
                local mem_gib=$(echo "$specs" | cut -d',' -f2)
                
                local cpu_util=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/RDS \
                    --metric-name CPUUtilization \
                    --dimensions Name=DBInstanceIdentifier,Value="$id" \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "Datapoints[0].Average" \
                    --output text)
                
                local avg_memory_percent="N/A"
                if [[ -n "$mem_gib" && "$mem_gib" != "N/A" ]]; then
                    local free_mem=$(aws cloudwatch get-metric-statistics --region "$region" \
                        --namespace AWS/RDS \
                        --metric-name FreeableMemory \
                        --dimensions Name=DBInstanceIdentifier,Value="$id" \
                        --start-time "$start_time" \
                        --end-time "$end_time" \
                        --period "$PERIOD" \
                        --statistics Average \
                        --query "Datapoints[0].Average" \
                        --output text)
                    local total_memory_bytes=$(echo "scale=0; $mem_gib * 1073741824" | bc)
                    if [ "${total_memory_bytes}" -gt 0 ]; then
                        avg_memory_percent=$(echo "scale=2; (1 - (${free_mem:-0} / ${total_memory_bytes})) * 100" | bc)
                    fi
                fi

                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$name" \
                    "$id" \
                    "$state" \
                    "RDS" \
                    "$engine" \
                    "$class" \
                    "N/A" \
                    "$create_time" \
                    "$vcpu" \
                    "$mem_gib" \
                    "$disk_gib" \
                    "${cpu_util:-N/A}" \
                    "${avg_memory_percent:-N/A}" \
                    "$region" >> "$FILENAME"
            done < <(echo "$rds_data" | jq -c '.[]')
        else
            log "  [RDS] No DB instances found."
        fi
        log "Region \033[1;33m$region\033[0m Complete."
    done
    log "✅ DONE. Results saved to: $FILENAME"
}

# Run the main function with all arguments passed to the script
main "$@"
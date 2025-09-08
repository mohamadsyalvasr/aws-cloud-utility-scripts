#!/bin/bash
# aws_ec2_report.sh
# Gathers a detailed report on EC2 instances, including specifications and average utilization metrics.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
SUM_ALL_EBS=false
TS=$(date +"%Y%m%d-%H%M%S")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
FILENAME="${OUTPUT_DIR}/aws_ec2_report_${TS}.csv"
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
Usage: $0 -b <start_date> -e <end_date> [-r regions] [-s] [-f filename] [-h]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -s               Enables the summation of all attached EBS volumes.
                   Default: Only calculates the root disk size.
  -f <filename>    Name of the output CSV file.
                   Default: aws_ec2_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script Logic ---
main() {
    check_dependencies
    
    while getopts "b:e:r:sf:h" opt; do
        case "$opt" in
            b) START_DATE="$OPTARG" ;;
            e) END_DATE="$OPTARG" ;;
            r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
            s) SUM_ALL_EBS=true ;;
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
    printf '"Name","Instance ID","Instance state","Type","Instance type","Elastic IP","Launch time","vCPUs","Memory (GiB)","Disk (GiB)","Average CPU %%","Average Memory %%","Region"\n' > "$FILENAME"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local ec2_data=$(aws ec2 describe-instances --region "$region" --query 'Reservations[].Instances[]' --output json)

        if [[ "$(echo "$ec2_data" | jq 'length')" -gt 0 ]]; then
            mapfile -t INSTANCE_TYPES < <(echo "$ec2_data" | jq -r '.[].InstanceType' | sort -u)
            declare -A INSTANCE_SPECS
            if [[ ${#INSTANCE_TYPES[@]} -gt 0 ]]; then
                log "  [EC2] Caching specs for ${#INSTANCE_TYPES[@]} instance types..."
                local type_specs=$(aws ec2 describe-instance-types --region "$region" --instance-types "${INSTANCE_TYPES[@]}" --query 'InstanceTypes[].{Type:InstanceType, Vcpu:VCpuInfo.DefaultVCpus, Mem:MemoryInfo.SizeInMiB}' --output json)
                
                while IFS= read -r spec; do
                    local type=$(echo "$spec" | jq -r '.Type')
                    local vcpu=$(echo "$spec" | jq -r '.Vcpu')
                    local mem_mib=$(echo "$spec" | jq -r '.Mem')
                    local mem_gib=$(awk "BEGIN {printf \"%.2f\", ${mem_mib}/1024}")
                    INSTANCE_SPECS["$type"]="$vcpu,$mem_gib"
                done < <(echo "$type_specs" | jq -c '.[]')
            fi

            log "  [EC2] Processing and writing to CSV..."
            while IFS= read -r instance; do
                local id=$(echo "$instance" | jq -r '.InstanceId')
                local state=$(echo "$instance" | jq -r '.State.Name')
                local type=$(echo "$instance" | jq -r '.InstanceType')
                local launch_time=$(echo "$instance" | jq -r '.LaunchTime')
                local name=$(echo "$instance" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
                local specs=${INSTANCE_SPECS[$type]:="N/A,N/A"}
                local vcpu=$(echo "$specs" | cut -d',' -f1)
                local mem_gib=$(echo "$specs" | cut -d',' -f2)
                
                local disk_gib=0
                if [[ "$SUM_ALL_EBS" == "true" ]]; then
                    mapfile -t vol_ids < <(echo "$instance" | jq -r '.BlockDeviceMappings[].Ebs.VolumeId')
                    if [[ ${#vol_ids[@]} -gt 0 ]]; then
                        disk_gib=$(aws ec2 describe-volumes --region "$region" --volume-ids "${vol_ids[@]}" --query 'sum(Volumes[].Size)' --output text)
                    fi
                else
                    local root_device=$(echo "$instance" | jq -r '.RootDeviceName')
                    if [[ "$root_device" != "null" ]]; then
                        local root_vol_id=$(echo "$instance" | jq -r --arg rd "$root_device" '.BlockDeviceMappings[] | select(.DeviceName==$rd).Ebs.VolumeId')
                        if [[ -n "$root_vol_id" ]]; then
                            disk_gib=$(aws ec2 describe-volumes --region "$region" --volume-id "$root_vol_id" --query 'Volumes[0].Size' --output text)
                        fi
                    fi
                fi
                disk_gib=${disk_gib:-0}

                local cpu_util=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/EC2 \
                    --metric-name CPUUtilization \
                    --dimensions Name=InstanceId,Value="$id" \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "Datapoints[0].Average" \
                    --output text)

                local avg_memory_percent=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace CWAgent \
                    --metric-name mem_used_percent \
                    --dimensions Name=InstanceId,Value="$id" \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "Datapoints[0].Average" \
                    --output text)
                
                if [ -z "$avg_memory_percent" ] || [ "$avg_memory_percent" = "null" ]; then
                    avg_memory_percent="N/A"
                fi
                
                local elastic_ip=$(echo "$instance" | jq -r '.PublicIpAddress // "N/A"')

                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$name" \
                    "$id" \
                    "$state" \
                    "EC2" \
                    "$type" \
                    "$elastic_ip" \
                    "$launch_time" \
                    "$vcpu" \
                    "$mem_gib" \
                    "$disk_gib" \
                    "${cpu_util:-N/A}" \
                    "${avg_memory_percent:-N/A}" \
                    "$region" >> "$FILENAME"
            done < <(echo "$ec2_data" | jq -c '.[]')
        else
            log "  [EC2] No instances found."
        fi
        log "Region \033[1;33m$region\033[0m Complete."
    done
    log "✅ DONE. Results saved to: $FILENAME"
}

# Run the main function with all arguments passed to the script
main "$@"
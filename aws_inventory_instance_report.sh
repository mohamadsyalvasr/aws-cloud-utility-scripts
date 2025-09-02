#!/bin/bash
# aws_inventory_instance_report.sh
# Script to combine EC2 and RDS reports into a single CSV file with specifications and average utilization
# based on a specified time period and regions.

# Exit immediately if a command fails
set -euo pipefail

########################################
# CONFIGURATION AND ARGUMENTS
########################################
# Default values
REGIONS=("ap-southeast-1" "ap-southeast-3")
SUM_ALL_EBS=false
TS=$(date +"%Y%m%d-%H%M%S")
FILENAME="aws_inventory_${TS}.csv"
START_DATE=""
END_DATE=""
PERIOD=2592000 # Default to ~30 days in seconds

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-s] [-f filename]

Options:
  -b <start_date>  Start date (YYYY-MM-DD) for average calculation. REQUIRED.
  -e <end_date>    End date (YYYY-MM-DD) for average calculation. REQUIRED.
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ap-southeast-1,ap-southeast-3
  -s               Enables the summation of all attached EBS volumes.
                   Default: Only calculates the root disk size.
  -f <filename>    Name of the output CSV file.
                   Default: aws_inventory_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

while getopts "b:e:r:sf:h" opt; do
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
        s)
            SUM_ALL_EBS=true
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

# Check for required arguments
if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)


########################################
# UTIL & PRECHECK
########################################
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

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

########################################
# MAIN SCRIPT
########################################
check_dependencies

log "✍️ Preparing output file: $FILENAME"
# Adjusted CSV Header
printf '"Name","Instance ID","Instance state","Type","Engine (RDS)","Instance type","Elastic IP","Launch time","vCPUs","Memory (GiB)","Disk (GiB)","Average CPU %%","Average Memory %%","Region"\n' > "$FILENAME"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- PROCESS EC2 ---
    log "  [EC2] Fetching instance data..."
    EC2_DATA=$(aws ec2 describe-instances --region "$region" --query 'Reservations[].Instances[]' --output json)

    if [[ "$(echo "$EC2_DATA" | jq 'length')" -gt 0 ]]; then
        mapfile -t INSTANCE_TYPES < <(echo "$EC2_DATA" | jq -r '.[].InstanceType' | sort -u)
        declare -A INSTANCE_SPECS
        if [[ ${#INSTANCE_TYPES[@]} -gt 0 ]]; then
            log "  [EC2] Caching specs for ${#INSTANCE_TYPES[@]} instance types..."
            TYPE_SPECS=$(aws ec2 describe-instance-types --region "$region" --instance-types "${INSTANCE_TYPES[@]}" --query 'InstanceTypes[].{Type:InstanceType, Vcpu:VCpuInfo.DefaultVCpus, Mem:MemoryInfo.SizeInMiB}' --output json)
            while IFS= read -r spec; do
                type=$(echo "$spec" | jq -r '.Type')
                vcpu=$(echo "$spec" | jq -r '.Vcpu')
                mem_mib=$(echo "$spec" | jq -r '.Mem')
                mem_gib=$(awk "BEGIN {printf \"%.2f\", ${mem_mib}/1024}")
                INSTANCE_SPECS["$type"]="$vcpu,$mem_gib"
            done < <(echo "$TYPE_SPECS" | jq -c '.[]')
        fi

        log "  [EC2] Processing and writing to CSV..."
        while IFS= read -r instance; do
            ID=$(echo "$instance" | jq -r '.InstanceId')
            STATE=$(echo "$instance" | jq -r '.State.Name')
            TYPE=$(echo "$instance" | jq -r '.InstanceType')
            LAUNCH_TIME=$(echo "$instance" | jq -r '.LaunchTime')
            NAME=$(echo "$instance" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "N/A"')
            SPECS=${INSTANCE_SPECS[$TYPE]:="N/A,N/A"}
            VCPU=$(echo "$SPECS" | cut -d',' -f1)
            MEM_GIB=$(echo "$SPECS" | cut -d',' -f2)
            DISK_GIB=0
            if [[ "$SUM_ALL_EBS" == "true" ]]; then
                mapfile -t VOL_IDS < <(echo "$instance" | jq -r '.BlockDeviceMappings[].Ebs.VolumeId')
                if [[ ${#VOL_IDS[@]} -gt 0 ]]; then
                    DISK_GIB=$(aws ec2 describe-volumes --region "$region" --volume-ids "${VOL_IDS[@]}" --query 'sum(Volumes[].Size)' --output text)
                fi
            else
                ROOT_DEVICE=$(echo "$instance" | jq -r '.RootDeviceName')
                if [[ "$ROOT_DEVICE" != "null" ]]; then
                    ROOT_VOL_ID=$(echo "$instance" | jq -r --arg rd "$ROOT_DEVICE" '.BlockDeviceMappings[] | select(.DeviceName==$rd).Ebs.VolumeId')
                    if [[ -n "$ROOT_VOL_ID" ]]; then
                        DISK_GIB=$(aws ec2 describe-volumes --region "$region" --volume-id "$ROOT_VOL_ID" --query 'Volumes[0].Size' --output text)
                    fi
                fi
            fi
            DISK_GIB=${DISK_GIB:-0}

            # Get Average CPU % from CloudWatch
            CPU_UTIL=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/EC2 \
                --metric-name CPUUtilization \
                --dimensions Name=InstanceId,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)

            # Check if memory metrics exist
            AVG_MEMORY_PERCENT=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace CWAgent \
                --metric-name mem_used_percent \
                --dimensions Name=InstanceId,Value="$ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Average \
                --query "Datapoints[0].Average" \
                --output text)
            
            # Fix: Add check for "null" string
            if [ -z "$AVG_MEMORY_PERCENT" ] || [ "$AVG_MEMORY_PERCENT" = "null" ]; then
                AVG_MEMORY_PERCENT="N/A"
            fi
            
            # Get Elastic IP (if any)
            ELASTIC_IP=$(echo "$instance" | jq -r '.PublicIpAddress')
            if [ "$ELASTIC_IP" = "null" ]; then
                ELASTIC_IP="N/A"
            fi

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$ID" \
                "$STATE" \
                "EC2" \
                "N/A" \
                "$TYPE" \
                "$ELASTIC_IP" \
                "$LAUNCH_TIME" \
                "$VCPU" \
                "$MEM_GIB" \
                "$DISK_GIB" \
                "${CPU_UTIL:-N/A}" \
                "${AVG_MEMORY_PERCENT:-N/A}" \
                "$region" >> "$FILENAME"
        done < <(echo "$EC2_DATA" | jq -c '.[]')
    else
        log "  [EC2] No instances found."
    fi

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
            
            AVG_MEMORY_PERCENT=$(echo "scale=2; (1 - (${FREE_MEM:-0} / ${TOTAL_MEMORY_BYTES:-1})) * 100" | bc)
            
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
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
                "${CPU_UTIL:-N/A}" \
                "${AVG_MEMORY_PERCENT:-N/A}" \
                "$region" >> "$FILENAME"
        done < <(echo "$RDS_DATA" | jq -c '.[]')
    else
        log "  [RDS] No DB instances found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Results saved to: $FILENAME"

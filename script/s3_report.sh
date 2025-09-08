#!/bin/bash
# s3_report.sh
# Gathers a report on all S3 buckets, using CloudWatch to get the total size.

set -euo pipefail

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/s3_report_$(date +"%Y%m%d-%H%M%S").csv"
PERIOD=86400 # Default to 1 day in seconds
START_DATE=""
END_DATE=""

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

    # The script expects START_DATE and END_DATE to be set,
    # usually by the main_report_runner.sh script.
    if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
        log "❌ START_DATE or END_DATE is not set. Please run this script from main_report_runner.sh"
        exit 1
    fi
    
    local start_time=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ")
    local end_time=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ")

    log "✍️ Preparing output file: $OUTPUT_FILE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    printf '"Bucket Name","Region","Total Objects","Total Size (GB)","Creation Date"\n' > "$OUTPUT_FILE"

    local bucket_data=$(aws s3api list-buckets --query 'Buckets[]' --output json)
    if [ "$(echo "$bucket_data" | jq 'length')" -eq 0 ]; then
        log "❌ No S3 buckets found in your account."
        return
    fi

    local total_buckets=$(echo "$bucket_data" | jq 'length')
    log "Total number of buckets found: $total_buckets"

    echo "$bucket_data" | jq -c '.[]' | while read -r bucket_info; do
        local bucket=$(echo "$bucket_info" | jq -r '.Name')
        local created_date=$(echo "$bucket_info" | jq -r '.CreationDate')
        
        log "Processing bucket: \033[1;33m$bucket\033[0m"

        local region=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text)
        if [ -z "$region" ] || [ "$region" = "null" ]; then
            region="us-east-1"
        fi

        local total_size_bytes=$(aws cloudwatch get-metric-statistics \
            --namespace "AWS/S3" \
            --metric-name "BucketSizeBytes" \
            --dimensions Name=BucketName,Value="$bucket" Name=StorageType,Value=StandardStorage \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --period "$PERIOD" \
            --statistics "Average" \
            --region "$region" \
            --query "Datapoints[0].Average" \
            --output text || echo "0")
            
        local object_count=$(aws cloudwatch get-metric-statistics \
            --namespace "AWS/S3" \
            --metric-name "NumberOfObjects" \
            --dimensions Name=BucketName,Value="$bucket" Name=StorageType,Value=AllStorageTypes \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --period "$PERIOD" \
            --statistics "Average" \
            --region "$region" \
            --query "Datapoints[0].Average" \
            --output text || echo "0")

        local total_size_gb=$(echo "scale=2; ${total_size_bytes} / 1073741824" | bc)

        printf '"%s","%s","%s","%s","%s"\n' \
            "$bucket" \
            "$region" \
            "$object_count" \
            "$total_size_gb" \
            "$created_date" >> "$OUTPUT_FILE"
    done
    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
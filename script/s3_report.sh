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
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/s3_report.csv"
# The following variables are now exported by main_report_runner.sh
# START_DATE=""
# END_DATE=""
PERIOD=86400 # Default to 1 day in seconds

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq, bc)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found. Please install it first."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found. Please install it first."
        exit 1
    fi
    if ! command -v bc >/dev/null 2>&1; then
        log "❌ bc not found. Please install it first."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Bucket Name","Region","Total Objects","Total Size (GB)","Creation Date"\n' > "$OUTPUT_FILE"

# Check if required variables are set by main_report_runner.sh
if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ START_DATE or END_DATE is not set. Please run this script from main_report_runner.sh"
    exit 1
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

BUCKET_DATA=$(aws s3api list-buckets --query 'Buckets[]' --output json)
if [ "$(echo "$BUCKET_DATA" | jq 'length')" -eq 0 ]; then
    log "❌ No S3 buckets found in your account."
    exit 0
fi

# Print the total number of buckets
TOTAL_BUCKETS=$(echo "$BUCKET_DATA" | jq 'length')
log "Total number of buckets found: $TOTAL_BUCKETS"

echo "$BUCKET_DATA" | jq -c '.[]' | while read -r bucket_info; do
    bucket=$(echo "$bucket_info" | jq -r '.Name')
    CREATED_DATE=$(echo "$bucket_info" | jq -r '.CreationDate')
    
    log "Processing bucket: \033[1;33m$bucket\033[0m"

    REGION=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text)
    if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
        REGION="us-east-1"
    fi

    # Get total size from CloudWatch
    TOTAL_SIZE_BYTES=$(aws cloudwatch get-metric-statistics \
        --namespace "AWS/S3" \
        --metric-name "BucketSizeBytes" \
        --dimensions Name=BucketName,Value="$bucket" Name=StorageType,Value=StandardStorage \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period "$PERIOD" \
        --statistics "Average" \
        --region "$REGION" \
        --query "Datapoints[0].Average" \
        --output text)
        
    # Get object count from CloudWatch
    OBJECT_COUNT=$(aws cloudwatch get-metric-statistics \
        --namespace "AWS/S3" \
        --metric-name "NumberOfObjects" \
        --dimensions Name=BucketName,Value="$bucket" Name=StorageType,Value=AllStorageTypes \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period "$PERIOD" \
        --statistics "Average" \
        --region "$REGION" \
        --query "Datapoints[0].Average" \
        --output text)

    # Handle null or empty values
    TOTAL_SIZE_BYTES=${TOTAL_SIZE_BYTES:-0}
    OBJECT_COUNT=${OBJECT_COUNT:-0}
    
    # Convert bytes to GB
    TOTAL_SIZE_GB=$(echo "scale=2; ${TOTAL_SIZE_BYTES} / 1073741824" | bc)

    printf '"%s","%s","%s","%s","%s"\n' \
        "$bucket" \
        "$REGION" \
        "$OBJECT_COUNT" \
        "$TOTAL_SIZE_GB" \
        "$CREATED_DATE" >> "$OUTPUT_FILE"
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# s3_bucket_size_report.sh
# Script to generate a report of all S3 buckets, including their total size.

# Exit immediately if a command fails
set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/s3_bucket_size_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

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
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header
printf '"Bucket Name","Creation Date","Region","Total Size (Bytes)"\n' > "$OUTPUT_FILE"

# Get a list of all S3 buckets
BUCKET_LIST=$(aws s3api list-buckets --output json)
if [[ "$(echo "$BUCKET_LIST" | jq '.Buckets | length')" -eq 0 ]]; then
    log "❌ No S3 buckets found in your account."
    exit 0
fi

# Process each bucket and write to CSV
echo "$BUCKET_LIST" | jq -c '.Buckets[]' | while read -r bucket_info; do
    BUCKET_NAME=$(echo "$bucket_info" | jq -r '.Name')
    CREATION_DATE=$(echo "$bucket_info" | jq -r '.CreationDate')
    
    log "Processing bucket: \033[1;33m$BUCKET_NAME\033[0m"

    # Get the bucket's region
    REGION=$(aws s3api get-bucket-location --bucket "$BUCKET_NAME" --query 'LocationConstraint' --output text)
    if [ -z "$REGION" ] || [ "$REGION" = "null" ]; then
        REGION="us-east-1"
    fi

    TOTAL_SIZE_BYTES=0
    CONTINUATION_TOKEN=""

    # Paginate through all objects to get total size
    while : ; do
        if [ -n "$CONTINUATION_TOKEN" ]; then
            OBJECTS=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --region "$REGION" --continuation-token "$CONTINUATION_TOKEN" --output json)
        else
            OBJECTS=$(aws s3api list-objects-v2 --bucket "$BUCKET_NAME" --region "$REGION" --output json)
        fi

        SIZE_PARTIAL=$(echo "$OBJECTS" | jq -r '[.Contents[].Size] | add // 0')
        TOTAL_SIZE_BYTES=$((TOTAL_SIZE_BYTES + SIZE_PARTIAL))

        CONTINUATION_TOKEN=$(echo "$OBJECTS" | jq -r '.NextContinuationToken // ""')
        
        if [ -z "$CONTINUATION_TOKEN" ]; then
            break
        fi
    done

    printf '"%s","%s","%s","%s"\n' \
        "$BUCKET_NAME" \
        "$CREATION_DATE" \
        "$REGION" \
        "$TOTAL_SIZE_BYTES" >> "$OUTPUT_FILE"
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"
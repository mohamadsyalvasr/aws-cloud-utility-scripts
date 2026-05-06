#!/bin/bash
# s3_storage_optimization_report.sh
# Generates a report on S3 buckets with suboptimal storage configurations,
# recommending lifecycle policies and storage class transitions to reduce costs.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/s3_storage_optimization_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # 30 days in seconds

# Source pricing helper for pricing functions
source ./lib/pricing_helper.sh

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for utilization metrics (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for utilization metrics (YYYY-MM-DD).
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

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# --- Helper Functions ---

# Get S3 pricing from fallback JSON
get_s3_price() {
    local price_key="$1"
    local region="$2"

    if [[ ! -f "$PRICING_FALLBACK_FILE" ]]; then
        echo ""
        return 1
    fi

    local price=""
    price=$(jq -r ".s3.\"${region}\".\"${price_key}\" // empty" "$PRICING_FALLBACK_FILE" 2>/dev/null)
    echo "$price"
}

# Get bucket size for a specific storage type from CloudWatch
get_bucket_size_bytes() {
    local bucket_name="$1"
    local region="$2"
    local storage_type="$3"

    local size_bytes=""
    size_bytes=$(aws cloudwatch get-metric-statistics --region "$region" \
        --namespace AWS/S3 \
        --metric-name BucketSizeBytes \
        --dimensions Name=BucketName,Value="$bucket_name" Name=StorageType,Value="$storage_type" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period 86400 \
        --statistics Average \
        --query "sort_by(Datapoints, &Timestamp)[-1].Average" \
        --output text 2>/dev/null) || true

    if [[ -z "$size_bytes" || "$size_bytes" == "None" || "$size_bytes" == "null" ]]; then
        echo "0"
    else
        echo "$size_bytes"
    fi
}

# Get request count (GetRequests + PutRequests) from CloudWatch
get_bucket_request_count() {
    local bucket_name="$1"
    local region="$2"
    local filter_id="$3"

    # Try AllRequests metric from S3 request metrics
    local total_requests=""
    total_requests=$(aws cloudwatch get-metric-statistics --region "$region" \
        --namespace AWS/S3 \
        --metric-name AllRequests \
        --dimensions Name=BucketName,Value="$bucket_name" Name=FilterId,Value="$filter_id" \
        --start-time "$START_TIME" \
        --end-time "$END_TIME" \
        --period "$PERIOD" \
        --statistics Sum \
        --query "sort_by(Datapoints, &Timestamp)[-1].Sum" \
        --output text 2>/dev/null) || true

    if [[ -z "$total_requests" || "$total_requests" == "None" || "$total_requests" == "null" ]]; then
        echo ""
    else
        echo "$total_requests"
    fi
}

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq, bc)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
    exit 1
fi
log "✅ Dependencies met."

log "📊 S3 Storage Optimization Analysis"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Bucket Name","Region","Total Size GB","Current Storage Class Distribution","Has Lifecycle Policy","Versioning","Last Access Pattern","Recommendation","Estimated Monthly Savings"\n' > "$OUTPUT_FILE"

# List all S3 buckets
log "📋 Listing all S3 buckets..."
BUCKETS_JSON=$(aws s3api list-buckets --query 'Buckets[].Name' --output json 2>/dev/null) || {
    log "❌ Failed to list S3 buckets. Check AWS credentials."
    exit 1
}

BUCKET_COUNT=$(echo "$BUCKETS_JSON" | jq 'length')
log "  Found $BUCKET_COUNT bucket(s) total"

S3_IDX=0
echo "$BUCKETS_JSON" | jq -r '.[]' | while read -r bucket_name; do
    S3_IDX=$((S3_IDX + 1))
    # Get bucket region
    bucket_region=$(aws s3api get-bucket-location --bucket "$bucket_name" \
        --query 'LocationConstraint' --output text 2>/dev/null) || {
        log "  ⚠️ Cannot determine region for bucket: $bucket_name (access denied or error)"
        continue
    }

    # Handle null location (us-east-1 returns "None" or "null")
    if [[ "$bucket_region" == "None" || "$bucket_region" == "null" || -z "$bucket_region" ]]; then
        bucket_region="us-east-1"
    fi

    # Check if bucket is in one of the specified regions
    region_match=false
    for region in "${REGIONS[@]}"; do
        if [[ "$bucket_region" == "$region" ]]; then
            region_match=true
            break
        fi
    done

    if [[ "$region_match" == "false" ]]; then
        continue
    fi

    log "  [$S3_IDX/$BUCKET_COUNT] Analyzing: $bucket_name (region: $bucket_region)"

    # --- Check lifecycle policy ---
    has_lifecycle="No"
    lifecycle_output=$(aws s3api get-bucket-lifecycle-configuration --bucket "$bucket_name" 2>&1) || true
    if echo "$lifecycle_output" | jq -e '.Rules' >/dev/null 2>&1; then
        has_lifecycle="Yes"
    fi

    # --- Check versioning status ---
    versioning_status=$(aws s3api get-bucket-versioning --bucket "$bucket_name" --output json 2>/dev/null) || versioning_status="{}"
    versioning=$(echo "$versioning_status" | jq -r '.Status // "Disabled"')

    # --- Get bucket size per storage type from CloudWatch ---
    standard_bytes=$(get_bucket_size_bytes "$bucket_name" "$bucket_region" "StandardStorage")
    ia_bytes=$(get_bucket_size_bytes "$bucket_name" "$bucket_region" "StandardIAStorage")
    it_fa_bytes=$(get_bucket_size_bytes "$bucket_name" "$bucket_region" "IntelligentTieringFAStorage")
    it_ia_bytes=$(get_bucket_size_bytes "$bucket_name" "$bucket_region" "IntelligentTieringIAStorage")
    glacier_bytes=$(get_bucket_size_bytes "$bucket_name" "$bucket_region" "GlacierStorage")
    deep_archive_bytes=$(get_bucket_size_bytes "$bucket_name" "$bucket_region" "DeepArchiveStorage")

    # Calculate total size in GB (1 GB = 1073741824 bytes)
    total_bytes=$(echo "$standard_bytes + $ia_bytes + $it_fa_bytes + $it_ia_bytes + $glacier_bytes + $deep_archive_bytes" | bc -l)
    total_gb=$(echo "$total_bytes / 1073741824" | bc -l 2>/dev/null | xargs printf "%.2f" 2>/dev/null) || total_gb="0.00"

    # Check if we have any metrics data
    if [[ $(echo "$total_bytes == 0" | bc -l) -eq 1 ]]; then
        # No CloudWatch metrics available - mark as insufficient data
        log "    ⚠️ No CloudWatch metrics available for $bucket_name"
        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$bucket_name" \
            "$bucket_region" \
            "N/A" \
            "N/A" \
            "$has_lifecycle" \
            "$versioning" \
            "Insufficient Data" \
            "Insufficient Data" \
            "N/A" >> "$OUTPUT_FILE"
        continue
    fi

    # --- Build storage class distribution string ---
    distribution_parts=()
    if [[ $(echo "$standard_bytes > 0" | bc -l) -eq 1 ]]; then
        standard_pct=$(echo "$standard_bytes / $total_bytes * 100" | bc -l | xargs printf "%.0f")
        distribution_parts+=("Standard: ${standard_pct}%")
    fi
    if [[ $(echo "$ia_bytes > 0" | bc -l) -eq 1 ]]; then
        ia_pct=$(echo "$ia_bytes / $total_bytes * 100" | bc -l | xargs printf "%.0f")
        distribution_parts+=("IA: ${ia_pct}%")
    fi
    if [[ $(echo "$it_fa_bytes + $it_ia_bytes > 0" | bc -l) -eq 1 ]]; then
        it_total=$(echo "$it_fa_bytes + $it_ia_bytes" | bc -l)
        it_pct=$(echo "$it_total / $total_bytes * 100" | bc -l | xargs printf "%.0f")
        distribution_parts+=("Intelligent-Tiering: ${it_pct}%")
    fi
    if [[ $(echo "$glacier_bytes > 0" | bc -l) -eq 1 ]]; then
        glacier_pct=$(echo "$glacier_bytes / $total_bytes * 100" | bc -l | xargs printf "%.0f")
        distribution_parts+=("Glacier: ${glacier_pct}%")
    fi
    if [[ $(echo "$deep_archive_bytes > 0" | bc -l) -eq 1 ]]; then
        da_pct=$(echo "$deep_archive_bytes / $total_bytes * 100" | bc -l | xargs printf "%.0f")
        distribution_parts+=("Deep Archive: ${da_pct}%")
    fi

    storage_distribution=$(IFS=', '; echo "${distribution_parts[*]}")
    if [[ -z "$storage_distribution" ]]; then
        storage_distribution="N/A"
    fi

    # --- Access pattern analysis ---
    # Try to get request metrics from CloudWatch (requires S3 request metrics to be enabled)
    access_pattern="Unknown"
    daily_requests=""

    # Try with common filter IDs
    request_count=$(get_bucket_request_count "$bucket_name" "$bucket_region" "EntireBucket")

    if [[ -z "$request_count" ]]; then
        # Try without filter ID - use NumberOfObjects as a proxy for activity
        request_count=""
    fi

    if [[ -n "$request_count" && "$request_count" != "0" ]]; then
        # Calculate days in analysis period
        start_epoch=$(date -u -d "$START_DATE" +%s)
        end_epoch=$(date -u -d "$END_DATE" +%s)
        days_in_period=$(( (end_epoch - start_epoch) / 86400 ))
        if [[ "$days_in_period" -lt 1 ]]; then
            days_in_period=1
        fi

        daily_requests=$(echo "$request_count / $days_in_period" | bc -l | xargs printf "%.1f")

        if [[ $(echo "$daily_requests < 1" | bc -l) -eq 1 ]]; then
            access_pattern="Very Low (< 1 req/day)"
        elif [[ $(echo "$daily_requests < 10" | bc -l) -eq 1 ]]; then
            access_pattern="Low (< 10 req/day)"
        elif [[ $(echo "$daily_requests < 100" | bc -l) -eq 1 ]]; then
            access_pattern="Moderate (< 100 req/day)"
        else
            access_pattern="High (100+ req/day)"
        fi
    fi

    # --- Generate recommendations ---
    recommendation="None"
    estimated_savings="0.00"
    standard_gb=$(echo "$standard_bytes / 1073741824" | bc -l | xargs printf "%.2f")
    total_gb_num=$(echo "$total_bytes / 1073741824" | bc -l)

    # Get S3 pricing for the bucket region
    price_standard=$(get_s3_price "standard_per_gb" "$bucket_region")
    price_ia=$(get_s3_price "standard_ia_per_gb" "$bucket_region")
    price_it_infrequent=$(get_s3_price "intelligent_tiering_infrequent_per_gb" "$bucket_region")
    price_glacier=$(get_s3_price "glacier_flexible_per_gb" "$bucket_region")
    price_deep_archive=$(get_s3_price "glacier_deep_archive_per_gb" "$bucket_region")

    # Default pricing if not available in fallback
    price_standard="${price_standard:-0.023}"
    price_ia="${price_ia:-0.0125}"
    price_it_infrequent="${price_it_infrequent:-0.0125}"
    price_glacier="${price_glacier:-0.0036}"
    price_deep_archive="${price_deep_archive:-0.00099}"

    # Recommendation logic:
    # 1. No lifecycle policy + size > 0: "Add lifecycle policy"
    # 2. Standard storage > 128 GB + low access: "Enable Intelligent-Tiering" or "Transition to S3 IA"
    # 3. Standard storage > 500 GB + very low access (< 1 request/day): "Transition to Glacier"

    standard_gb_num=$(echo "$standard_bytes / 1073741824" | bc -l)

    # Check for Glacier recommendation first (higher priority for large, rarely accessed data)
    if [[ $(echo "$standard_gb_num > 500" | bc -l) -eq 1 ]] && \
       [[ "$access_pattern" == "Very Low (< 1 req/day)" || "$access_pattern" == "Unknown" ]]; then
        # Very large bucket with very low access - recommend Glacier
        if [[ "$access_pattern" == "Unknown" ]]; then
            # If access pattern is unknown, only recommend if bucket is very large
            if [[ $(echo "$standard_gb_num > 500" | bc -l) -eq 1 ]]; then
                recommendation="Transition to Glacier (verify access patterns)"
                estimated_savings=$(echo "($price_standard - $price_glacier) * $standard_gb_num" | bc -l | xargs printf "%.2f")
            fi
        else
            recommendation="Transition to Glacier"
            estimated_savings=$(echo "($price_standard - $price_glacier) * $standard_gb_num" | bc -l | xargs printf "%.2f")
        fi
    # Check for Intelligent-Tiering / S3 IA recommendation
    elif [[ $(echo "$standard_gb_num > 128" | bc -l) -eq 1 ]] && \
         [[ "$access_pattern" == "Very Low (< 1 req/day)" || "$access_pattern" == "Low (< 10 req/day)" || "$access_pattern" == "Unknown" ]]; then
        if [[ "$access_pattern" == "Unknown" ]]; then
            recommendation="Enable Intelligent-Tiering (verify access patterns)"
        else
            recommendation="Enable Intelligent-Tiering"
        fi
        estimated_savings=$(echo "($price_standard - $price_it_infrequent) * $standard_gb_num" | bc -l | xargs printf "%.2f")
    # Check for lifecycle policy recommendation
    elif [[ "$has_lifecycle" == "No" ]] && [[ $(echo "$total_gb_num > 0" | bc -l) -eq 1 ]]; then
        recommendation="Add lifecycle policy"
        # Estimate savings assuming 30% of data could transition to IA
        eligible_gb=$(echo "$standard_gb_num * 0.30" | bc -l)
        estimated_savings=$(echo "($price_standard - $price_ia) * $eligible_gb" | bc -l | xargs printf "%.2f")
    # Check for versioning without lifecycle (old versions accumulate)
    elif [[ "$versioning" == "Enabled" ]] && [[ "$has_lifecycle" == "No" ]] && [[ $(echo "$total_gb_num > 50" | bc -l) -eq 1 ]]; then
        recommendation="Add lifecycle policy to expire old versions"
        # Old versions typically add 20% overhead
        estimated_savings=$(echo "$total_gb_num * $price_standard * 0.20" | bc -l | xargs printf "%.2f")
    fi

    # Ensure savings is non-negative
    if [[ -n "$estimated_savings" ]]; then
        savings_negative=$(echo "$estimated_savings < 0" | bc -l 2>/dev/null || echo "0")
        if [[ "$savings_negative" == "1" ]]; then
            estimated_savings="0.00"
        fi
    fi

    if [[ "$recommendation" == "None" ]]; then
        estimated_savings="0.00"
    fi

    log "    📦 Size: ${total_gb} GB | Storage: ${storage_distribution} | Lifecycle: ${has_lifecycle} | Versioning: ${versioning} | Access: ${access_pattern}"
    if [[ "$recommendation" != "None" ]]; then
        log "    💰 Recommendation: ${recommendation} | Savings: \$${estimated_savings}/month"
    fi

    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$bucket_name" \
        "$bucket_region" \
        "$total_gb" \
        "$storage_distribution" \
        "$has_lifecycle" \
        "$versioning" \
        "$access_pattern" \
        "$recommendation" \
        "$estimated_savings" >> "$OUTPUT_FILE"

done

log "✅ DONE. S3 Storage Optimization report saved to: $OUTPUT_FILE"

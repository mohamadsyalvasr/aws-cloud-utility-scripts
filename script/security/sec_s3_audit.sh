#!/bin/bash
# sec_s3_audit.sh
# S3 Bucket Security Audit - Manual fallback for S3 security checks.
# Checks: Public Access Block, encryption, logging, public bucket policy.
# Skips if Trusted Advisor already covered S3 category.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_s3_audit.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
Options:
  -r <regions>   Not used (S3 is global). Accepted for framework compatibility.
  -f <filename>  Custom output filename.
  -h             Show this help message.
EOF
    exit 1
}

while getopts "r:f:h" opt; do
    case "$opt" in
        r) : ;; # Accepted but not used
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Setup ---
mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Coverage Check ---
COVERAGE_FILE="${OUTPUT_DIR}/.ta_coverage"
MY_CATEGORY="S3"

if [[ -f "$COVERAGE_FILE" ]] && grep -q "^${MY_CATEGORY}$" "$COVERAGE_FILE"; then
    log "⏭️ Skipping ${MY_CATEGORY} audit — covered by Trusted Advisor"
    printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"
    exit 0
fi

# --- Main ---
log "📊 S3 Bucket Security Audit (Manual Fallback)"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

FINDING_COUNT=0

# Get list of all buckets
set +e
BUCKETS=$(aws s3api list-buckets --query 'Buckets[*].Name' --output json 2>/dev/null)
BUCKETS_EXIT=$?
set -e

if [[ $BUCKETS_EXIT -ne 0 ]] || [[ -z "$BUCKETS" ]] || [[ "$BUCKETS" == "[]" ]]; then
    log "  ⚠️ Could not list S3 buckets or no buckets found."
    log "✅ DONE. S3 audit complete. Found 0 finding(s)."
    exit 0
fi

BUCKET_COUNT=$(echo "$BUCKETS" | jq 'length')
log "  Found $BUCKET_COUNT bucket(s)"

BUCKET_IDX=0

echo "$BUCKETS" | jq -r '.[]' | while read -r bucket; do
    BUCKET_IDX=$((BUCKET_IDX + 1))
    log "    [$BUCKET_IDX/$BUCKET_COUNT] Checking: $bucket"

    # Determine bucket region
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$bucket" --query 'LocationConstraint' --output text 2>/dev/null) || BUCKET_REGION="us-east-1"
    if [[ "$BUCKET_REGION" == "None" ]] || [[ -z "$BUCKET_REGION" ]]; then
        BUCKET_REGION="us-east-1"
    fi

    # =========================================================================
    # 1. Check Public Access Block
    # =========================================================================
    set +e
    PAB=$(aws s3api get-public-access-block --bucket "$bucket" --output json 2>/dev/null)
    PAB_EXIT=$?
    set -e

    if [[ $PAB_EXIT -ne 0 ]]; then
        # No public access block configured
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Public Access Block not fully enabled" \
            "$bucket" \
            "Bucket $bucket has no Public Access Block configuration" \
            "High" \
            "Enable all four Public Access Block settings" \
            "$BUCKET_REGION" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    else
        BLOCK_PUBLIC_ACLS=$(echo "$PAB" | jq -r '.PublicAccessBlockConfiguration.BlockPublicAcls // false')
        IGNORE_PUBLIC_ACLS=$(echo "$PAB" | jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls // false')
        BLOCK_PUBLIC_POLICY=$(echo "$PAB" | jq -r '.PublicAccessBlockConfiguration.BlockPublicPolicy // false')
        RESTRICT_PUBLIC_BUCKETS=$(echo "$PAB" | jq -r '.PublicAccessBlockConfiguration.RestrictPublicBuckets // false')

        if [[ "$BLOCK_PUBLIC_ACLS" != "true" ]] || [[ "$IGNORE_PUBLIC_ACLS" != "true" ]] || \
           [[ "$BLOCK_PUBLIC_POLICY" != "true" ]] || [[ "$RESTRICT_PUBLIC_BUCKETS" != "true" ]]; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "Public Access Block not fully enabled" \
                "$bucket" \
                "Bucket $bucket does not have all four Public Access Block settings enabled" \
                "High" \
                "Enable all four Public Access Block settings" \
                "$BUCKET_REGION" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        fi
    fi

    # =========================================================================
    # 2. Check default encryption
    # =========================================================================
    set +e
    ENCRYPTION=$(aws s3api get-bucket-encryption --bucket "$bucket" --output json 2>/dev/null)
    ENC_EXIT=$?
    set -e

    if [[ $ENC_EXIT -ne 0 ]] || [[ -z "$ENCRYPTION" ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "No default encryption" \
            "$bucket" \
            "Bucket $bucket does not have default server-side encryption configured" \
            "High" \
            "Enable default encryption (SSE-S3 or SSE-KMS)" \
            "$BUCKET_REGION" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    # =========================================================================
    # 3. Check server access logging
    # =========================================================================
    set +e
    LOGGING=$(aws s3api get-bucket-logging --bucket "$bucket" --output json 2>/dev/null)
    LOG_EXIT=$?
    set -e

    if [[ $LOG_EXIT -eq 0 ]]; then
        LOG_ENABLED=$(echo "$LOGGING" | jq -r '.LoggingEnabled // empty')
        if [[ -z "$LOG_ENABLED" ]]; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "Server access logging not enabled" \
                "$bucket" \
                "Bucket $bucket does not have server access logging configured" \
                "Medium" \
                "Enable server access logging for audit trail" \
                "$BUCKET_REGION" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        fi
    fi

    # =========================================================================
    # 4. Check bucket policy for public access (Principal: *)
    # =========================================================================
    set +e
    POLICY=$(aws s3api get-bucket-policy --bucket "$bucket" --query 'Policy' --output text 2>/dev/null)
    POLICY_EXIT=$?
    set -e

    if [[ $POLICY_EXIT -eq 0 ]] && [[ -n "$POLICY" ]]; then
        # Check for Principal: "*" or Principal: {"AWS": "*"}
        if echo "$POLICY" | jq -e '
            .Statement[]? | select(
                .Effect == "Allow" and
                (.Principal == "*" or .Principal.AWS == "*" or (.Principal.AWS? // [] | if type == "array" then . else [.] end | any(. == "*")))
            )' &>/dev/null; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "Bucket policy allows public access" \
                "$bucket" \
                "Bucket $bucket has a policy with Principal:* allowing public access" \
                "Critical" \
                "Review and restrict bucket policy to specific principals" \
                "$BUCKET_REGION" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        fi
    fi
done

log "✅ DONE. S3 audit complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

#!/bin/bash
# sec_trusted_advisor.sh
# Trusted Advisor Security Integration - Primary data source for security findings.
# Queries AWS Trusted Advisor security category checks and produces:
# 1. sec_trusted_advisor.csv - Security findings from TA
# 2. .ta_coverage - Coverage map file listing categories covered by TA
#
# If TA is unavailable (no Business/Enterprise support), writes empty coverage
# file so all manual fallback scripts will run.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_trusted_advisor.csv"
COVERAGE_FILE="${OUTPUT_DIR}/.ta_coverage"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
Options:
  -r <regions>   Not used (TA is global). Accepted for framework compatibility.
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

# --- Temp file for tracking covered categories (avoids subshell variable issue) ---
COVERED_CATS_FILE=$(mktemp)
trap 'rm -f "$COVERED_CATS_FILE"' EXIT

# --- Category Mapping ---
map_to_category() {
    local check_name="$1"
    local name_lower=$(echo "$check_name" | tr '[:upper:]' '[:lower:]')

    if echo "$name_lower" | grep -qE "mfa|access key|password policy|iam"; then
        echo "IAM"
    elif echo "$name_lower" | grep -qE "security group|port|unrestricted"; then
        echo "SG"
    elif echo "$name_lower" | grep -qE "s3|bucket"; then
        echo "S3"
    elif echo "$name_lower" | grep -qE "cloudtrail|logging|trail"; then
        echo "LOGGING"
    else
        echo "OTHER"
    fi
}

# --- Severity Mapping ---
map_ta_status_to_severity() {
    local status="$1"
    case "$status" in
        error)   echo "Critical" ;;
        warning) echo "High" ;;
        *)       echo "" ;; # ok, not_available — skip
    esac
}

# --- Main ---
log "📊 Trusted Advisor Security Integration"
log "✍️ Preparing output files..."
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

# Try to get Trusted Advisor checks
log "📋 Fetching Trusted Advisor security checks..."
set +e
TA_RESULT=$(aws support describe-trusted-advisor-checks --language en --region us-east-1 --output json 2>&1)
TA_EXIT=$?
set -e

if [ $TA_EXIT -ne 0 ]; then
    if echo "$TA_RESULT" | grep -qi "SubscriptionRequiredException\|AccessDenied\|not authorized"; then
        log "⚠️ Trusted Advisor not available (requires Business/Enterprise support plan)"
        log "   All manual fallback scripts will run."
        # Write empty coverage file — signals all fallbacks to run
        echo "# Trusted Advisor unavailable - all manual fallbacks will execute" > "$COVERAGE_FILE"
        log "✅ DONE. Coverage file written (empty - fallback mode activated)"
        exit 0
    else
        log "⚠️ Unexpected error from Trusted Advisor: $TA_RESULT"
        echo "# Trusted Advisor error - all manual fallbacks will execute" > "$COVERAGE_FILE"
        exit 0
    fi
fi

# Filter security category checks
SECURITY_CHECKS=$(echo "$TA_RESULT" | jq -c '[.checks[] | select(.category == "security")]')
CHECK_COUNT=$(echo "$SECURITY_CHECKS" | jq 'length')

if [ "$CHECK_COUNT" -eq 0 ]; then
    log "⚠️ No security checks found in Trusted Advisor"
    echo "# No security checks found" > "$COVERAGE_FILE"
    log "✅ DONE."
    exit 0
fi

log "  Found $CHECK_COUNT security check(s)"

CHECK_IDX=0

echo "$SECURITY_CHECKS" | jq -c '.[]' | while read -r check; do
    CHECK_IDX=$((CHECK_IDX + 1))
    CHECK_ID=$(echo "$check" | jq -r '.id')
    CHECK_NAME=$(echo "$check" | jq -r '.name')

    log "  [$CHECK_IDX/$CHECK_COUNT] Processing: $CHECK_NAME"

    # Get check result
    set +e
    RESULT=$(aws support describe-trusted-advisor-check-result \
        --check-id "$CHECK_ID" \
        --language en \
        --region us-east-1 \
        --output json 2>/dev/null)
    RESULT_EXIT=$?
    set -e

    if [ $RESULT_EXIT -ne 0 ] || [ -z "$RESULT" ]; then
        log "    ⚠️ Failed to get result for: $CHECK_NAME. Skipping."
        continue
    fi

    STATUS=$(echo "$RESULT" | jq -r '.result.status')
    SEVERITY=$(map_ta_status_to_severity "$STATUS")

    # Skip checks with ok/not_available status
    if [ -z "$SEVERITY" ]; then
        # Still map category for coverage tracking (TA checked it even if ok)
        CATEGORY=$(map_to_category "$CHECK_NAME")
        if [ "$CATEGORY" != "OTHER" ]; then
            echo "$CATEGORY" >> "$COVERED_CATS_FILE"
        fi
        continue
    fi

    # Map to internal category
    CATEGORY=$(map_to_category "$CHECK_NAME")

    # Track category as covered
    if [ "$CATEGORY" != "OTHER" ]; then
        echo "$CATEGORY" >> "$COVERED_CATS_FILE"
    fi

    # Process flagged resources
    FLAGGED=$(echo "$RESULT" | jq -c '.result.flaggedResources // []')
    FLAGGED_COUNT=$(echo "$FLAGGED" | jq 'length')

    if [ "$FLAGGED_COUNT" -gt 0 ]; then
        echo "$FLAGGED" | jq -c '.[]' | while read -r resource; do
            # Extract resource metadata (TA returns array of metadata values)
            RESOURCE_ID=$(echo "$resource" | jq -r '.metadata[0] // .resourceId // "N/A"')
            DETAIL=$(echo "$resource" | jq -r '.metadata | join(", ")' 2>/dev/null || echo "N/A")
            REGION_VAL=$(echo "$resource" | jq -r '.region // "Global"')

            # Escape quotes in detail for CSV
            DETAIL=$(echo "$DETAIL" | sed 's/"/""/g' | head -c 200)

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$CHECK_NAME" \
                "$RESOURCE_ID" \
                "$DETAIL" \
                "$SEVERITY" \
                "Review and remediate per AWS best practices" \
                "$REGION_VAL" >> "$OUTPUT_FILE"
        done

        log "    Found $FLAGGED_COUNT flagged resource(s) [$SEVERITY]"
    fi
done

# Write coverage file from temp file (deduplicated, excluding OTHER)
log "📝 Writing coverage map..."
{
    echo "# Written by sec_trusted_advisor.sh at $(date +'%Y-%m-%d %H:%M:%S')"
    echo "# Categories with Trusted Advisor coverage"
    sort -u "$COVERED_CATS_FILE" | grep -v "^OTHER$" | grep -v "^$" || true
} > "$COVERAGE_FILE"

COVERED_COUNT=$(sort -u "$COVERED_CATS_FILE" | grep -v "^OTHER$" | grep -v "^$" | wc -l || echo "0")
COVERED_LIST=$(sort -u "$COVERED_CATS_FILE" | grep -v "^OTHER$" | grep -v "^$" | tr '\n' ' ' || echo "none")
log "  Categories covered by TA: $COVERED_COUNT (${COVERED_LIST:-none})"
log "✅ DONE. Trusted Advisor report saved to: $OUTPUT_FILE"
log "   Coverage map saved to: $COVERAGE_FILE"

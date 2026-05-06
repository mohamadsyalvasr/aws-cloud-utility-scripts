#!/bin/bash
# trusted_advisor_report.sh
# Pulls cost optimization recommendations from AWS Trusted Advisor.
# NOTE: Requires Business or Enterprise Support plan.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/trusted_advisor_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")  # Not used - TA is global via us-east-1
START_DATE=""
END_DATE=""

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Argument Parsing ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-b <start_date>] [-e <end_date>] [-f filename] [-h]

Options:
  -b <start_date>  The start date (YYYY-MM-DD). Not used by TA but accepted for compatibility.
  -e <end_date>    The end date (YYYY-MM-DD). Not used by TA but accepted for compatibility.
  -r <regions>     Comma-separated list of AWS regions (not used - TA is global). Accepted for compatibility.
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

while getopts "b:e:r:f:h" opt; do
    case "$opt" in
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."
    exit 1
fi
log "✅ Dependencies met."

log "📊 Trusted Advisor Cost Optimization Report"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

# CSV header
printf '"Check Name","Status","Resources Flagged","Estimated Monthly Savings","Description","Region"\n' > "$OUTPUT_FILE"

# Get all Trusted Advisor checks
log "📋 Fetching Trusted Advisor checks..."
TA_CHECKS=$(aws support describe-trusted-advisor-checks --language en --region us-east-1 --output json 2>/dev/null) || {
    log "⚠️ Trusted Advisor not available (requires Business/Enterprise support plan). Skipping."
    exit 0
}

# Filter for cost_optimizing category
COST_CHECKS=$(echo "$TA_CHECKS" | jq -c '[.checks[] | select(.category == "cost_optimizing")]')
CHECK_COUNT=$(echo "$COST_CHECKS" | jq 'length')

if [[ "$CHECK_COUNT" -eq 0 ]]; then
    log "⚠️ No cost optimization checks found."
    exit 0
fi

log "  Found $CHECK_COUNT cost optimization check(s)"

CHECK_IDX=0
echo "$COST_CHECKS" | jq -c '.[]' | while read -r check; do
    CHECK_IDX=$((CHECK_IDX + 1))
    CHECK_ID=$(echo "$check" | jq -r '.id')
    CHECK_NAME=$(echo "$check" | jq -r '.name')

    log "  [$CHECK_IDX/$CHECK_COUNT] Processing: $CHECK_NAME"

    # Get check result
    RESULT=$(aws support describe-trusted-advisor-check-result --check-id "$CHECK_ID" --language en --region us-east-1 --output json 2>/dev/null) || {
        log "    ⚠️ Failed to get result for: $CHECK_NAME. Skipping."
        continue
    }

    STATUS=$(echo "$RESULT" | jq -r '.result.status')
    FLAGGED_COUNT=$(echo "$RESULT" | jq '.result.flaggedResources | length')

    # Extract estimated savings if available
    ESTIMATED_SAVINGS=$(echo "$RESULT" | jq -r '.result.categorySpecificSummary.costOptimizing.estimatedMonthlySavings // "N/A"')

    # Get description from check metadata (truncate to 200 chars)
    DESCRIPTION=$(echo "$check" | jq -r '.description' | tr -d '\n' | head -c 200)
    # Escape double quotes in description for CSV
    DESCRIPTION=$(echo "$DESCRIPTION" | sed 's/"/""/g')

    printf '"%s","%s","%s","%s","%s","%s"\n' \
        "$CHECK_NAME" "$STATUS" "$FLAGGED_COUNT" "$ESTIMATED_SAVINGS" "$DESCRIPTION" "Global" >> "$OUTPUT_FILE"
done

log "✅ DONE. Trusted Advisor report saved to: $OUTPUT_FILE"

#!/bin/bash
# cloudfront_report.sh
# Gathers a report on CloudFront Distributions (Global).

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/cloudfront_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependencies ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Id","DomainName","Status","Enabled","LastModifiedTime","Comment"\n' > "$OUTPUT_FILE"

log "Processing CloudFront Distributions (Global)..."

# CloudFront is global.
DIST_DATA=$(aws cloudfront list-distributions --output json)

if [[ "$(echo "$DIST_DATA" | jq -r '.DistributionList.Quantity // 0')" -gt 0 ]]; then
    # Parse Items array
    echo "$DIST_DATA" | jq -r '.DistributionList.Items[] | [.Id, .DomainName, .Status, .Enabled, .LastModifiedTime, .Comment] | @csv' >> "$OUTPUT_FILE"
else
    log "  [CloudFront] No distributions found."
fi

log "✅ DONE. Report saved to: $OUTPUT_FILE"

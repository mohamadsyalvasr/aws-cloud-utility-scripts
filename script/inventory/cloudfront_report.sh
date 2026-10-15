#!/bin/bash
# cloudfront_report.sh
# Gathers a report on CloudFront Distributions (Global).

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/cloudfront_report.csv"

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

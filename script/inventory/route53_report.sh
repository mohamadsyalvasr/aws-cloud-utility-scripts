#!/bin/bash
# route53_report.sh
# Gathers an inventory report on Route 53 Hosted Zones and record counts.
# Route 53 is a global service.

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/route53_report.csv"

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Zone Name","Zone ID","Type","Record Count","Comment"\n' > "$OUTPUT_FILE"

log "Processing Route 53 Hosted Zones (Global)..."

ZONES_DATA=$(aws route53 list-hosted-zones --output json --no-paginate 2>/dev/null || echo '{"HostedZones":[]}')

ZONE_COUNT=$(echo "$ZONES_DATA" | jq '.HostedZones | length')

if [[ "$ZONE_COUNT" -eq 0 ]]; then
    log "  [Route 53] No hosted zones found."
else
    log "  [Route 53] Found $ZONE_COUNT hosted zones."
    echo "$ZONES_DATA" | jq -c '.HostedZones[]' | while read -r zone; do
        ZONE_NAME=$(echo "$zone" | jq -r '.Name')
        ZONE_ID=$(echo "$zone" | jq -r '.Id' | sed 's|/hostedzone/||')
        ZONE_TYPE=$(echo "$zone" | jq -r 'if .Config.PrivateZone then "Private" else "Public" end')
        RECORD_COUNT=$(echo "$zone" | jq -r '.ResourceRecordSetCount // "N/A"')
        COMMENT=$(echo "$zone" | jq -r '.Config.Comment // "N/A"')

        printf '"%s","%s","%s","%s","%s"\n' \
            "$ZONE_NAME" \
            "$ZONE_ID" \
            "$ZONE_TYPE" \
            "$RECORD_COUNT" \
            "$COMMENT" >> "$OUTPUT_FILE"
    done
fi

log "✅ DONE. Report saved to: $OUTPUT_FILE"

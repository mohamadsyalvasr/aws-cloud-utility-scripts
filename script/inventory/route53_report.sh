#!/bin/bash
# route53_report.sh
# Gathers an inventory report on Route 53 Hosted Zones and record counts.
# Route 53 is a global service.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/route53_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

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

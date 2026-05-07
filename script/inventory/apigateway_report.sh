#!/bin/bash
# apigateway_report.sh
# Gathers an inventory report on all API Gateway REST APIs and HTTP/WebSocket APIs.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/apigateway_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]
Options:
  -r <regions>     Comma-separated list of AWS regions. Default: ${REGIONS[*]}
  -h               Show this help message.
EOF
    exit 1
}

while getopts "r:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

# --- Main Script ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"API Name","API ID","API Type","Protocol Type","Endpoint Type","Created Date","Description","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    FOUND_COUNT=0

    # --- REST APIs (API Gateway v1) ---
    REST_DATA=$(aws apigateway get-rest-apis --region "$region" --output json --no-paginate 2>/dev/null || echo '{"items":[]}')
    REST_COUNT=$(echo "$REST_DATA" | jq '.items // [] | length')

    if [[ "$REST_COUNT" -gt 0 ]]; then
        log "  [API Gateway] Found $REST_COUNT REST APIs."
        FOUND_COUNT=$((FOUND_COUNT + REST_COUNT))

        echo "$REST_DATA" | jq -c '.items // [] | .[]' | while read -r api; do
            API_NAME=$(echo "$api" | jq -r '.name // "N/A"')
            API_ID=$(echo "$api" | jq -r '.id // "N/A"')
            API_TYPE="REST"
            PROTOCOL_TYPE="REST"
            ENDPOINT_TYPE=$(echo "$api" | jq -r '.endpointConfiguration.types[0] // "N/A"')
            CREATED_DATE=$(echo "$api" | jq -r '.createdDate // "N/A"')
            DESCRIPTION=$(echo "$api" | jq -r '.description // "N/A"' | sed 's/"/""/g')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$API_NAME" \
                "$API_ID" \
                "$API_TYPE" \
                "$PROTOCOL_TYPE" \
                "$ENDPOINT_TYPE" \
                "$CREATED_DATE" \
                "$DESCRIPTION" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    # --- HTTP/WebSocket APIs (API Gateway v2) ---
    V2_DATA=$(aws apigatewayv2 get-apis --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Items":[]}')
    V2_COUNT=$(echo "$V2_DATA" | jq '.Items // [] | length')

    if [[ "$V2_COUNT" -gt 0 ]]; then
        log "  [API Gateway] Found $V2_COUNT HTTP/WebSocket APIs."
        FOUND_COUNT=$((FOUND_COUNT + V2_COUNT))

        echo "$V2_DATA" | jq -c '.Items // [] | .[]' | while read -r api; do
            API_NAME=$(echo "$api" | jq -r '.Name // "N/A"')
            API_ID=$(echo "$api" | jq -r '.ApiId // "N/A"')
            PROTOCOL_TYPE=$(echo "$api" | jq -r '.ProtocolType // "N/A"')
            if [[ "$PROTOCOL_TYPE" == "HTTP" ]]; then
                API_TYPE="HTTP"
            elif [[ "$PROTOCOL_TYPE" == "WEBSOCKET" ]]; then
                API_TYPE="WebSocket"
            else
                API_TYPE="$PROTOCOL_TYPE"
            fi
            ENDPOINT_TYPE="REGIONAL"
            CREATED_DATE=$(echo "$api" | jq -r '.CreatedDate // "N/A"')
            DESCRIPTION=$(echo "$api" | jq -r '.Description // "N/A"' | sed 's/"/""/g')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$API_NAME" \
                "$API_ID" \
                "$API_TYPE" \
                "$PROTOCOL_TYPE" \
                "$ENDPOINT_TYPE" \
                "$CREATED_DATE" \
                "$DESCRIPTION" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    if [[ "$FOUND_COUNT" -eq 0 ]]; then
        log "  [API Gateway] No APIs found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

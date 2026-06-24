#!/bin/bash
# edge_topology.sh
# Discovers edge/CDN architecture: Route 53 → CloudFront → Origins (S3/ELB/Custom)
# Outputs a Mermaid diagram.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/architecture_edge_topology.md"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-h]
Options:
  -h               Show this help message.

Note: Route 53 and CloudFront are global services. No region flag needed.
EOF
    exit 1
}

while getopts "h" opt; do
    case "$opt" in
        h) usage ;;
        *) usage ;;
    esac
done

# --- Dependency Check ---
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

# --- Main ---
log "✍️ Generating edge/CDN topology diagram..."
mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<'HEADER'
# Edge & CDN Architecture Topology

Auto-generated diagram showing Route 53 → CloudFront → Origin relationships.

HEADER

echo '```mermaid' >> "$OUTPUT_FILE"
echo "graph LR" >> "$OUTPUT_FILE"
echo "    INTERNET((\"🌍 Internet\"))" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

# --- CloudFront Distributions ---
log "  Discovering CloudFront distributions..."
CF_DATA=$(aws cloudfront list-distributions --output json 2>/dev/null || echo '{"DistributionList":{"Quantity":0}}')
CF_COUNT=$(echo "$CF_DATA" | jq '.DistributionList.Quantity // 0')

if [[ "$CF_COUNT" -gt 0 ]]; then
    log "  Found $CF_COUNT CloudFront distributions."

    echo "$CF_DATA" | jq -c '.DistributionList.Items[]?' | while read -r dist; do
        CF_ID=$(echo "$dist" | jq -r '.Id')
        CF_DOMAIN=$(echo "$dist" | jq -r '.DomainName')
        CF_STATUS=$(echo "$dist" | jq -r '.Status')
        CF_ALIASES=$(echo "$dist" | jq -r '.Aliases.Items[]? // empty' | head -3 | tr '\n' ', ' | sed 's/,$//')
        CF_NODE="CF_${CF_ID//[-.]/_}"

        if [[ -n "$CF_ALIASES" ]]; then
            echo "    ${CF_NODE}[\"☁️ CloudFront<br/>$CF_ID<br/>$CF_ALIASES\"]" >> "$OUTPUT_FILE"
        else
            echo "    ${CF_NODE}[\"☁️ CloudFront<br/>$CF_ID\"]" >> "$OUTPUT_FILE"
        fi

        echo "    INTERNET --> ${CF_NODE}" >> "$OUTPUT_FILE"

        # --- Origins ---
        echo "$dist" | jq -c '.Origins.Items[]?' | while read -r origin; do
            ORIGIN_DOMAIN=$(echo "$origin" | jq -r '.DomainName')
            ORIGIN_ID=$(echo "$origin" | jq -r '.Id')
            ORIGIN_NODE="ORIGIN_${ORIGIN_ID//[-.]/_}"

            if [[ "$ORIGIN_DOMAIN" == *".s3."* || "$ORIGIN_DOMAIN" == *".s3-"* || "$ORIGIN_DOMAIN" == *".s3.amazonaws.com" ]]; then
                # S3 origin
                BUCKET_NAME=$(echo "$ORIGIN_DOMAIN" | sed 's/.s3.*//' | sed 's/.s3-.*//')
                echo "    ${CF_NODE} --> ${ORIGIN_NODE}[\"🪣 S3: $BUCKET_NAME\"]" >> "$OUTPUT_FILE"

            elif [[ "$ORIGIN_DOMAIN" == *".elb."* || "$ORIGIN_DOMAIN" == *"elb.amazonaws.com"* ]]; then
                # ELB origin
                echo "    ${CF_NODE} --> ${ORIGIN_NODE}[\"⚖️ ELB: $ORIGIN_DOMAIN\"]" >> "$OUTPUT_FILE"

            elif [[ "$ORIGIN_DOMAIN" == *".execute-api."* ]]; then
                # API Gateway origin
                echo "    ${CF_NODE} --> ${ORIGIN_NODE}[\"🌐 API GW: $ORIGIN_DOMAIN\"]" >> "$OUTPUT_FILE"

            elif [[ "$ORIGIN_DOMAIN" == *".mediastore."* ]]; then
                # MediaStore origin
                echo "    ${CF_NODE} --> ${ORIGIN_NODE}[\"🎬 MediaStore: $ORIGIN_DOMAIN\"]" >> "$OUTPUT_FILE"

            else
                # Custom origin
                echo "    ${CF_NODE} --> ${ORIGIN_NODE}[\"🖥️ Custom: $ORIGIN_DOMAIN\"]" >> "$OUTPUT_FILE"
            fi
        done
    done
else
    log "  No CloudFront distributions found."
    echo "    %% No CloudFront distributions found" >> "$OUTPUT_FILE"
fi

echo "" >> "$OUTPUT_FILE"

# --- Route 53 Hosted Zones ---
log "  Discovering Route 53 hosted zones and alias records..."
ZONES=$(aws route53 list-hosted-zones --output json --no-paginate 2>/dev/null || echo '{"HostedZones":[]}')
ZONE_COUNT=$(echo "$ZONES" | jq '.HostedZones | length')

if [[ "$ZONE_COUNT" -gt 0 ]]; then
    log "  Found $ZONE_COUNT hosted zones. Checking alias records..."

    echo "$ZONES" | jq -c '.HostedZones[]' | while read -r zone; do
        ZONE_ID=$(echo "$zone" | jq -r '.Id' | sed 's|/hostedzone/||')
        ZONE_NAME=$(echo "$zone" | jq -r '.Name' | sed 's/\.$//')
        ZONE_NODE="R53_${ZONE_ID//[-.]/_}"

        echo "    ${ZONE_NODE}[\"🗺️ Route53: $ZONE_NAME\"]" >> "$OUTPUT_FILE"

        # Get alias records that point to CloudFront or ELB
        RECORDS=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
            --output json --no-paginate 2>/dev/null || echo '{"ResourceRecordSets":[]}')

        echo "$RECORDS" | jq -c '.ResourceRecordSets[] | select(.AliasTarget != null)' | while read -r record; do
            RECORD_NAME=$(echo "$record" | jq -r '.Name' | sed 's/\.$//')
            ALIAS_TARGET=$(echo "$record" | jq -r '.AliasTarget.DNSName' | sed 's/\.$//')

            if [[ "$ALIAS_TARGET" == *"cloudfront.net"* ]]; then
                # Find matching CF distribution
                CF_MATCH=$(echo "$CF_DATA" | jq -r --arg domain "$ALIAS_TARGET" \
                    '.DistributionList.Items[]? | select(.DomainName == $domain) | .Id' 2>/dev/null | head -1)
                if [[ -n "$CF_MATCH" ]]; then
                    echo "    ${ZONE_NODE} -->|\"$RECORD_NAME\"| CF_${CF_MATCH//[-.]/_}" >> "$OUTPUT_FILE"
                fi

            elif [[ "$ALIAS_TARGET" == *"elb."* || "$ALIAS_TARGET" == *"elb.amazonaws.com"* ]]; then
                ELB_NODE="ELB_ALIAS_${RECORD_NAME//[-.]/_}"
                echo "    ${ZONE_NODE} -->|\"$RECORD_NAME\"| ${ELB_NODE}[\"⚖️ $ALIAS_TARGET\"]" >> "$OUTPUT_FILE"

            elif [[ "$ALIAS_TARGET" == *".s3-website"* || "$ALIAS_TARGET" == *".s3.amazonaws.com"* ]]; then
                S3_NODE="S3_ALIAS_${RECORD_NAME//[-.]/_}"
                echo "    ${ZONE_NODE} -->|\"$RECORD_NAME\"| ${S3_NODE}[\"🪣 S3 Website: $ALIAS_TARGET\"]" >> "$OUTPUT_FILE"
            fi
        done
    done
else
    log "  No Route 53 hosted zones found."
fi

echo '```' >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

log "✅ DONE. Edge topology saved to: $OUTPUT_FILE"

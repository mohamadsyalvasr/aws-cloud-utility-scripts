#!/bin/bash
# opensearch_report.sh
# Gathers an inventory report on all OpenSearch (Elasticsearch) domains.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/opensearch_report.csv"

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

printf '"Domain Name","Domain ARN","Engine Version","Instance Type","Instance Count","Storage Type","EBS Volume Size (GB)","VPC ID","Endpoint","Creation Date","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # List all domain names
    DOMAINS_DATA=$(aws opensearch list-domain-names --region "$region" --output json 2>/dev/null || echo '{"DomainNames":[]}')
    DOMAIN_NAMES=$(echo "$DOMAINS_DATA" | jq -r '.DomainNames // [] | .[].DomainName' 2>/dev/null)

    if [[ -z "$DOMAIN_NAMES" ]]; then
        log "  [OpenSearch] No domains found."
        log "Region \033[1;33m$region\033[0m Complete."
        continue
    fi

    # Convert to array
    DOMAIN_ARRAY=()
    while IFS= read -r name; do
        [[ -n "$name" ]] && DOMAIN_ARRAY+=("$name")
    done <<< "$DOMAIN_NAMES"

    DOMAIN_COUNT=${#DOMAIN_ARRAY[@]}
    log "  [OpenSearch] Found $DOMAIN_COUNT domains. Fetching details..."

    # Process in batches of 5
    for ((i=0; i<DOMAIN_COUNT; i+=5)); do
        BATCH=("${DOMAIN_ARRAY[@]:i:5}")
        BATCH_ARGS=$(printf '%s ' "${BATCH[@]}")

        DETAILS=$(aws opensearch describe-domains --region "$region" \
            --domain-names $BATCH_ARGS --output json 2>/dev/null || echo '{"DomainStatusList":[]}')

        echo "$DETAILS" | jq -c '.DomainStatusList // [] | .[]' | while read -r domain; do
            DOMAIN_NAME=$(echo "$domain" | jq -r '.DomainName // "N/A"')
            DOMAIN_ARN=$(echo "$domain" | jq -r '.ARN // "N/A"')
            ENGINE_VERSION=$(echo "$domain" | jq -r '.EngineVersion // "N/A"')
            INSTANCE_TYPE=$(echo "$domain" | jq -r '.ClusterConfig.InstanceType // "N/A"')
            INSTANCE_COUNT=$(echo "$domain" | jq -r '.ClusterConfig.InstanceCount // "N/A"')
            STORAGE_TYPE=$(echo "$domain" | jq -r '.EBSOptions.VolumeType // "N/A"')
            EBS_SIZE=$(echo "$domain" | jq -r '.EBSOptions.VolumeSize // "N/A"')
            VPC_ID=$(echo "$domain" | jq -r '.VPCOptions.VPCId // "N/A"')

            # Endpoint depends on VPC vs public
            ENDPOINT=$(echo "$domain" | jq -r '.Endpoints.vpc // .Endpoint // "N/A"')
            if [[ "$ENDPOINT" == "null" || -z "$ENDPOINT" ]]; then
                ENDPOINT="N/A"
            fi

            CREATION_DATE=$(echo "$domain" | jq -r '.Created // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$DOMAIN_NAME" \
                "$DOMAIN_ARN" \
                "$ENGINE_VERSION" \
                "$INSTANCE_TYPE" \
                "$INSTANCE_COUNT" \
                "$STORAGE_TYPE" \
                "$EBS_SIZE" \
                "$VPC_ID" \
                "$ENDPOINT" \
                "$CREATION_DATE" \
                "$region" >> "$OUTPUT_FILE"
        done
    done

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

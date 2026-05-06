#!/bin/bash
# ses_report.sh
# Gathers an inventory report on Amazon SES identities (email addresses and domains).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ses_report.csv"

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

printf '"Identity","Type","Verification Status","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # List all identities (emails and domains)
    IDENTITIES=$(aws ses list-identities --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Identities":[]}')

    IDENTITY_LIST=$(echo "$IDENTITIES" | jq -r '.Identities[]' 2>/dev/null)

    if [[ -z "$IDENTITY_LIST" ]]; then
        log "  [SES] No identities found."
    else
        IDENTITY_COUNT=$(echo "$IDENTITIES" | jq '.Identities | length')
        log "  [SES] Found $IDENTITY_COUNT identities. Fetching verification status..."

        # Get verification attributes for all identities in one call
        VERIF_DATA=$(aws ses get-identity-verification-attributes --region "$region" \
            --identities $(echo "$IDENTITIES" | jq -r '.Identities[]') \
            --output json 2>/dev/null || echo '{"VerificationAttributes":{}}')

        echo "$IDENTITIES" | jq -r '.Identities[]' | while read -r identity; do
            # Determine type: if contains @, it's email; otherwise domain
            if [[ "$identity" == *"@"* ]]; then
                IDENTITY_TYPE="EmailAddress"
            else
                IDENTITY_TYPE="Domain"
            fi

            # Get verification status
            VERIF_STATUS=$(echo "$VERIF_DATA" | jq -r --arg id "$identity" \
                '.VerificationAttributes[$id].VerificationStatus // "N/A"')

            printf '"%s","%s","%s","%s"\n' \
                "$identity" \
                "$IDENTITY_TYPE" \
                "$VERIF_STATUS" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

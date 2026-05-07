#!/bin/bash
# secrets_manager_report.sh
# Gathers an inventory report on AWS Secrets Manager secrets.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/secrets_manager_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions.
                   Default: ${REGIONS[*]}
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

printf '"Secret Name","ARN","Description","Rotation Enabled","Last Rotated","Last Accessed","Created Date","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    SECRETS_DATA=$(aws secretsmanager list-secrets --region "$region" --output json --no-paginate 2>/dev/null || echo '{"SecretList":[]}')

    SECRET_COUNT=$(echo "$SECRETS_DATA" | jq '.SecretList | length')

    if [[ "$SECRET_COUNT" -eq 0 ]]; then
        log "  [Secrets Manager] No secrets found."
    else
        log "  [Secrets Manager] Found $SECRET_COUNT secrets."
        echo "$SECRETS_DATA" | jq -c '.SecretList[]' | while read -r secret; do
            SECRET_NAME=$(echo "$secret" | jq -r '.Name // "N/A"')
            SECRET_ARN=$(echo "$secret" | jq -r '.ARN // "N/A"')
            DESCRIPTION=$(echo "$secret" | jq -r '.Description // "N/A"' | sed 's/"/""/g')
            ROTATION_ENABLED=$(echo "$secret" | jq -r '.RotationEnabled // false')
            LAST_ROTATED=$(echo "$secret" | jq -r '.LastRotatedDate // "N/A"')
            LAST_ACCESSED=$(echo "$secret" | jq -r '.LastAccessedDate // "N/A"')
            CREATED_DATE=$(echo "$secret" | jq -r '.CreatedDate // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$SECRET_NAME" \
                "$SECRET_ARN" \
                "$DESCRIPTION" \
                "$ROTATION_ENABLED" \
                "$LAST_ROTATED" \
                "$LAST_ACCESSED" \
                "$CREATED_DATE" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# kms_report.sh
# Gathers an inventory report on all KMS (Key Management Service) keys.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/kms_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[*]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: kms_report.csv
  -h               Show this help message.
EOF
    exit 1
}

while getopts "r:f:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found. Please install it first."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found. Please install it first."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Create CSV header
printf '"Alias","Key ID","Key ARN","Key State","Key Usage","Key Spec","Key Manager","Origin","Creation Date","Description","Rotation Enabled","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # List all KMS keys in the region (--no-paginate to get all)
    KEYS_DATA=$(aws kms list-keys --region "$region" --query "Keys[]" --output json --no-paginate)

    if [[ "$(echo "$KEYS_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [KMS] No keys found."
        log "Region \033[1;33m$region\033[0m Complete."
        continue
    fi

    KEY_COUNT=$(echo "$KEYS_DATA" | jq 'length')
    log "  [KMS] Found $KEY_COUNT keys. Fetching details..."

    # Pre-fetch all aliases for this region to avoid N+1 calls
    ALIASES_DATA=$(aws kms list-aliases --region "$region" --output json --no-paginate)

    echo "$KEYS_DATA" | jq -c '.[]' | while read -r key_entry; do
        KEY_ID=$(echo "$key_entry" | jq -r '.KeyId')

        # Describe the key to get full metadata
        KEY_DETAILS=$(aws kms describe-key --region "$region" --key-id "$KEY_ID" --output json 2>/dev/null || echo "{}")

        if [[ -z "$KEY_DETAILS" || "$KEY_DETAILS" == "{}" ]]; then
            log "    ⚠️ Could not describe key: $KEY_ID"
            continue
        fi

        KEY_ARN=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.Arn // "N/A"')
        KEY_STATE=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.KeyState // "N/A"')
        KEY_USAGE=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.KeyUsage // "N/A"')
        KEY_SPEC=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.KeySpec // "N/A"')
        KEY_MANAGER=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.KeyManager // "N/A"')
        ORIGIN=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.Origin // "N/A"')
        CREATION_DATE=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.CreationDate // "N/A"')
        DESCRIPTION=$(echo "$KEY_DETAILS" | jq -r '.KeyMetadata.Description // "N/A"')

        # Get alias for this key from pre-fetched aliases data
        ALIAS=$(echo "$ALIASES_DATA" | jq -r --arg kid "$KEY_ID" \
            '[.Aliases[] | select(.TargetKeyId == $kid) | .AliasName] | join(", ") // "N/A"')
        if [[ -z "$ALIAS" ]]; then
            ALIAS="N/A"
        fi

        # Get rotation status (only for customer managed symmetric keys)
        ROTATION_ENABLED="N/A"
        if [[ "$KEY_MANAGER" == "CUSTOMER" && "$KEY_SPEC" == "SYMMETRIC_DEFAULT" && "$KEY_STATE" == "Enabled" ]]; then
            ROTATION_STATUS=$(aws kms get-key-rotation-status --region "$region" --key-id "$KEY_ID" \
                --query "KeyRotationEnabled" --output text 2>/dev/null || echo "N/A")
            if [[ "$ROTATION_STATUS" == "True" ]]; then
                ROTATION_ENABLED="Yes"
            elif [[ "$ROTATION_STATUS" == "False" ]]; then
                ROTATION_ENABLED="No"
            fi
        fi

        # Escape double quotes in description for CSV safety
        DESCRIPTION_ESCAPED=$(echo "$DESCRIPTION" | sed 's/"/""/g')

        printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$ALIAS" \
            "$KEY_ID" \
            "$KEY_ARN" \
            "$KEY_STATE" \
            "$KEY_USAGE" \
            "$KEY_SPEC" \
            "$KEY_MANAGER" \
            "$ORIGIN" \
            "$CREATION_DATE" \
            "$DESCRIPTION_ESCAPED" \
            "$ROTATION_ENABLED" \
            "$region" >> "$OUTPUT_FILE"
    done

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

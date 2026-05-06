#!/bin/bash
# ecr_report.sh
# Gathers an inventory report on all ECR (Elastic Container Registry) repositories.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/ecr_report.csv"

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
                   Default: ecr_report.csv
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
printf '"Repository Name","Repository URI","Image Count","Image Tag Mutability","Scan on Push","Encryption Type","Created At","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Describe all repositories (--no-paginate to get all)
    REPO_DATA=$(aws ecr describe-repositories --region "$region" --query "repositories[]" --output json --no-paginate 2>/dev/null || echo "[]")

    if [[ "$(echo "$REPO_DATA" | jq 'length')" -eq 0 ]]; then
        log "  [ECR] No repositories found."
        log "Region \033[1;33m$region\033[0m Complete."
        continue
    fi

    REPO_COUNT=$(echo "$REPO_DATA" | jq 'length')
    log "  [ECR] Found $REPO_COUNT repositories. Fetching image counts..."

    echo "$REPO_DATA" | jq -c '.[]' | while read -r repo; do
        REPO_NAME=$(echo "$repo" | jq -r '.repositoryName')
        REPO_URI=$(echo "$repo" | jq -r '.repositoryUri')
        TAG_MUTABILITY=$(echo "$repo" | jq -r '.imageTagMutability // "N/A"')
        SCAN_ON_PUSH=$(echo "$repo" | jq -r '.imageScanningConfiguration.scanOnPush // false')
        ENCRYPTION_TYPE=$(echo "$repo" | jq -r '.encryptionConfiguration.encryptionType // "AES256"')
        CREATED_AT=$(echo "$repo" | jq -r '.createdAt // "N/A"')

        # Get image count for this repository
        IMAGE_COUNT=$(aws ecr list-images --region "$region" --repository-name "$REPO_NAME" \
            --query "length(imageIds)" --output text --no-paginate 2>/dev/null || echo "0")

        # Handle null/empty
        IMAGE_COUNT=${IMAGE_COUNT:-0}
        if [[ "$IMAGE_COUNT" == "None" || "$IMAGE_COUNT" == "null" ]]; then
            IMAGE_COUNT="0"
        fi

        printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "$REPO_NAME" \
            "$REPO_URI" \
            "$IMAGE_COUNT" \
            "$TAG_MUTABILITY" \
            "$SCAN_ON_PUSH" \
            "$ENCRYPTION_TYPE" \
            "$CREATED_AT" \
            "$region" >> "$OUTPUT_FILE"
    done

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

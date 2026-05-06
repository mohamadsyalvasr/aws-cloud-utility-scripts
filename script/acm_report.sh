#!/bin/bash
# acm_report.sh
# Gathers an inventory report on AWS Certificate Manager (ACM) certificates.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/acm_report.csv"

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

printf '"Domain Name","Certificate ARN","Status","Type","Key Algorithm","Issuer","Not Before","Not After","In Use","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # List all certificates
    CERT_ARNS=$(aws acm list-certificates --region "$region" \
        --query "CertificateSummaryList[].CertificateArn" --output json --no-paginate 2>/dev/null || echo "[]")

    CERT_COUNT=$(echo "$CERT_ARNS" | jq 'length')

    if [[ "$CERT_COUNT" -eq 0 ]]; then
        log "  [ACM] No certificates found."
    else
        log "  [ACM] Found $CERT_COUNT certificates. Fetching details..."
        echo "$CERT_ARNS" | jq -r '.[]' | while read -r cert_arn; do
            # Describe each certificate for full details
            CERT_DETAILS=$(aws acm describe-certificate --region "$region" \
                --certificate-arn "$cert_arn" --output json 2>/dev/null || echo '{"Certificate":{}}')

            DOMAIN=$(echo "$CERT_DETAILS" | jq -r '.Certificate.DomainName // "N/A"')
            STATUS=$(echo "$CERT_DETAILS" | jq -r '.Certificate.Status // "N/A"')
            TYPE=$(echo "$CERT_DETAILS" | jq -r '.Certificate.Type // "N/A"')
            KEY_ALGO=$(echo "$CERT_DETAILS" | jq -r '.Certificate.KeyAlgorithm // "N/A"')
            ISSUER=$(echo "$CERT_DETAILS" | jq -r '.Certificate.Issuer // "N/A"')
            NOT_BEFORE=$(echo "$CERT_DETAILS" | jq -r '.Certificate.NotBefore // "N/A"')
            NOT_AFTER=$(echo "$CERT_DETAILS" | jq -r '.Certificate.NotAfter // "N/A"')
            IN_USE_COUNT=$(echo "$CERT_DETAILS" | jq -r '.Certificate.InUseBy | length // 0')

            if [[ "$IN_USE_COUNT" -gt 0 ]]; then
                IN_USE="Yes ($IN_USE_COUNT)"
            else
                IN_USE="No"
            fi

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$DOMAIN" \
                "$cert_arn" \
                "$STATUS" \
                "$TYPE" \
                "$KEY_ALGO" \
                "$ISSUER" \
                "$NOT_BEFORE" \
                "$NOT_AFTER" \
                "$IN_USE" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

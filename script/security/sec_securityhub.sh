#!/bin/bash
# sec_securityhub.sh
# Security Hub Integration - Always runs manually (not covered by Trusted Advisor).
# Retrieves active findings from AWS Security Hub with severity mapping.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_securityhub.csv"
REGIONS=("ap-southeast-1")

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
Options:
  -r <regions>   Comma-separated list of AWS regions to scan.
  -f <filename>  Custom output filename.
  -h             Show this help message.
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
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Setup ---
mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Severity Mapping ---
map_severity() {
    local sev="$1"
    case "$sev" in
        CRITICAL)      echo "Critical" ;;
        HIGH)          echo "High" ;;
        MEDIUM)        echo "Medium" ;;
        LOW)           echo "Low" ;;
        INFORMATIONAL) echo "Low" ;;
        *)             echo "Medium" ;;
    esac
}

# --- Main ---
log "📊 Security Hub Integration"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

FINDING_COUNT=0
REGION_COUNT=${#REGIONS[@]}
REGION_IDX=0

for region in "${REGIONS[@]}"; do
    REGION_IDX=$((REGION_IDX + 1))
    log "  [$REGION_IDX/$REGION_COUNT] Processing region: \033[1;33m$region\033[0m"

    # Check if Security Hub is enabled by attempting to get findings
    set +e
    FINDINGS_JSON=$(aws securityhub get-findings --region "$region" \
        --filters '{
            "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}],
            "WorkflowStatus": [
                {"Value": "NEW", "Comparison": "EQUALS"},
                {"Value": "NOTIFIED", "Comparison": "EQUALS"}
            ]
        }' \
        --max-items 500 \
        --output json 2>&1)
    SH_EXIT=$?
    set -e

    if [[ $SH_EXIT -ne 0 ]]; then
        if echo "$FINDINGS_JSON" | grep -qi "not subscribed\|not enabled\|InvalidAccessException\|AccessDeniedException"; then
            log "    ⚠️ Security Hub not enabled in $region. Skipping."
            continue
        else
            log "    ⚠️ Error querying Security Hub in $region. Skipping."
            continue
        fi
    fi

    # Parse findings
    FINDINGS=$(echo "$FINDINGS_JSON" | jq -c '.Findings // []' 2>/dev/null)
    if [[ -z "$FINDINGS" ]] || [[ "$FINDINGS" == "null" ]]; then
        log "    No findings returned"
        continue
    fi

    FINDINGS_COUNT=$(echo "$FINDINGS" | jq 'length' 2>/dev/null || echo "0")
    log "    Found $FINDINGS_COUNT active finding(s)"

    if [[ "$FINDINGS_COUNT" -gt 0 ]]; then
        echo "$FINDINGS" | jq -c '.[]' | while read -r finding; do
            TITLE=$(echo "$finding" | jq -r '.Title // "Unknown Finding"' | sed 's/"/""/g' | head -c 150)
            SEVERITY_LABEL=$(echo "$finding" | jq -r '.Severity.Label // "MEDIUM"')
            GENERATOR_ID=$(echo "$finding" | jq -r '.GeneratorId // "N/A"' | sed 's/"/""/g')
            COMPLIANCE_STATUS=$(echo "$finding" | jq -r '.Compliance.Status // "N/A"')

            # Get first resource ARN
            RESOURCE_ARN=$(echo "$finding" | jq -r '.Resources[0].Id // "N/A"' | sed 's/"/""/g')

            # Build detail string
            DETAIL="Generator: ${GENERATOR_ID}, Compliance: ${COMPLIANCE_STATUS}"
            DETAIL=$(echo "$DETAIL" | head -c 200)

            # Map severity
            MAPPED_SEVERITY=$(map_severity "$SEVERITY_LABEL")

            # Get recommendation
            RECOMMENDATION=$(echo "$finding" | jq -r '.Remediation.Recommendation.Text // "Review finding in Security Hub console"' | sed 's/"/""/g' | head -c 150)

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$TITLE" \
                "$RESOURCE_ARN" \
                "$DETAIL" \
                "$MAPPED_SEVERITY" \
                "$RECOMMENDATION" \
                "$region" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        done
    fi

    log "    Region $region complete."
done

log "✅ DONE. Security Hub integration complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

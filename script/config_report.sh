#!/bin/bash
# config_report.sh
# Gathers an inventory report on all AWS Config rules and their compliance status.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/config_report.csv"

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

printf '"Rule Name","Rule ARN","Source","Compliance Status","Noncompliant Resource Count","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all Config rules
    RULES_DATA=$(aws configservice describe-config-rules --region "$region" --output json --no-paginate 2>/dev/null || echo '{"ConfigRules":[]}')
    RULE_COUNT=$(echo "$RULES_DATA" | jq '.ConfigRules // [] | length')

    if [[ "$RULE_COUNT" -eq 0 ]]; then
        log "  [AWS Config] No Config rules found."
    else
        log "  [AWS Config] Found $RULE_COUNT Config rules. Fetching compliance..."

        # Get compliance data for all rules
        COMPLIANCE_DATA=$(aws configservice describe-compliance-by-config-rule --region "$region" \
            --output json --no-paginate 2>/dev/null || echo '{"ComplianceByConfigRules":[]}')

        echo "$RULES_DATA" | jq -c '.ConfigRules // [] | .[]' | while read -r rule; do
            RULE_NAME=$(echo "$rule" | jq -r '.ConfigRuleName // "N/A"')
            RULE_ARN=$(echo "$rule" | jq -r '.ConfigRuleArn // "N/A"')

            # Determine source type
            SOURCE_OWNER=$(echo "$rule" | jq -r '.Source.Owner // "N/A"')
            if [[ "$SOURCE_OWNER" == "AWS" ]]; then
                SOURCE="AWS Managed"
            elif [[ "$SOURCE_OWNER" == "CUSTOM_LAMBDA" || "$SOURCE_OWNER" == "CUSTOM_POLICY" ]]; then
                SOURCE="Custom"
            else
                SOURCE="$SOURCE_OWNER"
            fi

            # Get compliance status from pre-fetched data
            COMPLIANCE_STATUS=$(echo "$COMPLIANCE_DATA" | jq -r --arg name "$RULE_NAME" \
                '.ComplianceByConfigRules[] | select(.ConfigRuleName == $name) | .Compliance.ComplianceType // "N/A"')
            if [[ -z "$COMPLIANCE_STATUS" ]]; then
                COMPLIANCE_STATUS="N/A"
            fi

            # Get noncompliant resource count
            NONCOMPLIANT_COUNT=$(echo "$COMPLIANCE_DATA" | jq -r --arg name "$RULE_NAME" \
                '.ComplianceByConfigRules[] | select(.ConfigRuleName == $name) | .Compliance.ComplianceContributorCount.CappedCount // "N/A"')
            if [[ -z "$NONCOMPLIANT_COUNT" ]]; then
                NONCOMPLIANT_COUNT="N/A"
            fi

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$RULE_NAME" \
                "$RULE_ARN" \
                "$SOURCE" \
                "$COMPLIANCE_STATUS" \
                "$NONCOMPLIANT_COUNT" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

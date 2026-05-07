#!/bin/bash
# sec_logging_audit.sh
# Logging & Monitoring Audit - Manual fallback for logging security checks.
# Checks: CloudTrail multi-region trail, GuardDuty enabled, AWS Config recorder.
# Skips if Trusted Advisor already covered LOGGING category.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_logging_audit.csv"
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

# --- Coverage Check ---
COVERAGE_FILE="${OUTPUT_DIR}/.ta_coverage"
MY_CATEGORY="LOGGING"

if [[ -f "$COVERAGE_FILE" ]] && grep -q "^${MY_CATEGORY}$" "$COVERAGE_FILE"; then
    log "⏭️ Skipping ${MY_CATEGORY} audit — covered by Trusted Advisor"
    printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"
    exit 0
fi

# --- Main ---
log "📊 Logging & Monitoring Audit (Manual Fallback)"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

FINDING_COUNT=0
REGION_COUNT=${#REGIONS[@]}
REGION_IDX=0

# =========================================================================
# 1. Check CloudTrail for multi-region trail (global check)
# =========================================================================
log "  [1/3] Checking CloudTrail for multi-region trail..."
set +e
TRAILS=$(aws cloudtrail describe-trails --query 'trailList' --output json 2>/dev/null)
TRAILS_EXIT=$?
set -e

MULTI_REGION_FOUND=0
if [[ $TRAILS_EXIT -eq 0 ]] && [[ -n "$TRAILS" ]] && [[ "$TRAILS" != "[]" ]]; then
    MULTI_REGION_FOUND=$(echo "$TRAILS" | jq '[.[] | select(.IsMultiRegionTrail == true)] | length')
fi

if [[ "$MULTI_REGION_FOUND" -eq 0 ]]; then
    printf '"%s","%s","%s","%s","%s","%s"\n' \
        "No multi-region CloudTrail" \
        "CloudTrail" \
        "No multi-region CloudTrail trail is configured for this account" \
        "Critical" \
        "Create a multi-region CloudTrail trail for comprehensive audit logging" \
        "Global" >> "$OUTPUT_FILE"
    FINDING_COUNT=$((FINDING_COUNT + 1))
    log "    ❌ No multi-region CloudTrail found"
else
    log "    ✅ Multi-region CloudTrail found ($MULTI_REGION_FOUND trail(s))"
fi

# =========================================================================
# 2 & 3. Check GuardDuty and Config per region
# =========================================================================
for region in "${REGIONS[@]}"; do
    REGION_IDX=$((REGION_IDX + 1))
    log "  [$REGION_IDX/$REGION_COUNT] Processing region: \033[1;33m$region\033[0m"

    # =====================================================================
    # 2. Check GuardDuty
    # =====================================================================
    log "    [2/3] Checking GuardDuty..."
    set +e
    GD_DETECTORS=$(aws guardduty list-detectors --region "$region" --query 'DetectorIds' --output json 2>/dev/null)
    GD_EXIT=$?
    set -e

    if [[ $GD_EXIT -ne 0 ]]; then
        log "      ⚠️ GuardDuty not available in $region. Skipping."
    else
        GD_COUNT=$(echo "$GD_DETECTORS" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$GD_COUNT" -eq 0 ]]; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "GuardDuty not enabled" \
                "GuardDuty" \
                "GuardDuty has no active detectors in region $region" \
                "High" \
                "Enable GuardDuty for threat detection" \
                "$region" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
            log "      ❌ GuardDuty not enabled"
        else
            log "      ✅ GuardDuty enabled ($GD_COUNT detector(s))"
        fi
    fi

    # =====================================================================
    # 3. Check AWS Config
    # =====================================================================
    log "    [3/3] Checking AWS Config..."
    set +e
    CONFIG_RECORDERS=$(aws configservice describe-configuration-recorders --region "$region" --output json 2>/dev/null)
    CONFIG_EXIT=$?
    set -e

    if [[ $CONFIG_EXIT -ne 0 ]]; then
        log "      ⚠️ AWS Config not available in $region. Skipping."
    else
        RECORDER_COUNT=$(echo "$CONFIG_RECORDERS" | jq '.ConfigurationRecorders | length' 2>/dev/null || echo "0")
        if [[ "$RECORDER_COUNT" -eq 0 ]]; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "AWS Config not enabled" \
                "ConfigService" \
                "AWS Config has no configuration recorders in region $region" \
                "Medium" \
                "Enable AWS Config to track resource configuration changes" \
                "$region" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
            log "      ❌ AWS Config not enabled"
        else
            # Check if recorder is actually recording
            set +e
            RECORDER_STATUS=$(aws configservice describe-configuration-recorder-status --region "$region" --output json 2>/dev/null)
            set -e
            IS_RECORDING=$(echo "$RECORDER_STATUS" | jq '[.ConfigurationRecordersStatus[] | select(.recording == true)] | length' 2>/dev/null || echo "0")
            if [[ "$IS_RECORDING" -eq 0 ]]; then
                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "AWS Config not enabled" \
                    "ConfigService" \
                    "AWS Config recorder exists but is not actively recording in region $region" \
                    "Medium" \
                    "Start the AWS Config recorder to track configuration changes" \
                    "$region" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
                log "      ❌ AWS Config recorder not recording"
            else
                log "      ✅ AWS Config enabled and recording"
            fi
        fi
    fi

    log "    Region $region complete."
done

log "✅ DONE. Logging & Monitoring audit complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

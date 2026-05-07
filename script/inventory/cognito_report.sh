#!/bin/bash
# cognito_report.sh
# Gathers a report on Amazon Cognito User Pools.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/cognito_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
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

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Pool ID","Pool Name","Status","User Count","MFA Config","Creation Date","Region"\n' > "$OUTPUT_FILE"

TOTAL=${#REGIONS[@]}
COUNT=0

for region in "${REGIONS[@]}"; do
    COUNT=$((COUNT + 1))
    log "[$COUNT/$TOTAL] Processing Region: \033[1;33m$region\033[0m"

    POOLS=$(aws cognito-idp list-user-pools --max-results 60 --region "$region" --output json 2>/dev/null || true)

    if [[ -n "$POOLS" && "$(echo "$POOLS" | jq '.UserPools | length')" -gt 0 ]]; then
        POOL_IDS=$(echo "$POOLS" | jq -r '.UserPools[].Id')
        while IFS= read -r pool_id; do
            [[ -z "$pool_id" ]] && continue
            DETAIL=$(aws cognito-idp describe-user-pool --user-pool-id "$pool_id" --region "$region" --output json 2>/dev/null || true)
            if [[ -n "$DETAIL" ]]; then
                echo "$DETAIL" | jq -r --arg r "$region" '.UserPool | [
                    .Id,
                    .Name,
                    (.Status // "Active"),
                    (.EstimatedNumberOfUsers | tostring),
                    (.MfaConfiguration // "OFF"),
                    .CreationDate,
                    $r
                ] | @csv' >> "$OUTPUT_FILE"
            fi
        done <<< "$POOL_IDS"
    else
        log "  No Cognito User Pools found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

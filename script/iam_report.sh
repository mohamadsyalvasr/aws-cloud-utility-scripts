#!/bin/bash
# iam_report.sh
# Gathers a report on IAM Users (Global).

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/iam_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependencies ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"UserName","UserId","CreateDate","PasswordLastUsed"\n' > "$OUTPUT_FILE"

log "Processing IAM Users (Global)..."

USERS_DATA=$(aws iam list-users --output json)

if [[ "$(echo "$USERS_DATA" | jq '.Users | length')" -gt 0 ]]; then
    echo "$USERS_DATA" | jq -r '.Users[] | [.UserName, .UserId, .CreateDate, (.PasswordLastUsed // "N/A")] | @csv' >> "$OUTPUT_FILE"
else
    log "  [IAM] No users found."
fi

log "✅ DONE. Report saved to: $OUTPUT_FILE"

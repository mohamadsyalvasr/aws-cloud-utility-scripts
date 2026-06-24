#!/bin/bash
# iam_report.sh
# Gathers a report on IAM Users (Global) including Access Key status and MFA.

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
log "🔎 Checking dependencies (aws cli, jq)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."
    exit 1
fi
log "✅ Dependencies met."

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"UserName","UserId","CreateDate","PasswordLastUsed","Access Key 1","Key 1 Status","Key 1 Last Used","Access Key 2","Key 2 Status","Key 2 Last Used","MFA Enabled"\n' > "$OUTPUT_FILE"

log "Processing IAM Users (Global)..."

USERS_DATA=$(aws iam list-users --output json 2>/dev/null) || {
    log "❌ Failed to list IAM users."
    exit 1
}

USER_COUNT=$(echo "$USERS_DATA" | jq '.Users | length')

if [[ "$USER_COUNT" -eq 0 ]]; then
    log "  [IAM] No users found."
    log "✅ DONE. Report saved to: $OUTPUT_FILE"
    exit 0
fi

log "  Found $USER_COUNT user(s)"

IDX=0
echo "$USERS_DATA" | jq -c '.Users[]' | while read -r user; do
    IDX=$((IDX + 1))
    USERNAME=$(echo "$user" | jq -r '.UserName')
    USERID=$(echo "$user" | jq -r '.UserId')
    CREATE_DATE=$(echo "$user" | jq -r '.CreateDate')
    PASSWORD_LAST_USED=$(echo "$user" | jq -r '.PasswordLastUsed // "N/A"')

    log "  [$IDX/$USER_COUNT] Processing: $USERNAME"

    # --- Get Access Keys ---
    ACCESS_KEYS=$(aws iam list-access-keys --user-name "$USERNAME" --output json 2>/dev/null) || ACCESS_KEYS='{"AccessKeyMetadata":[]}'

    KEY1_ID="N/A"
    KEY1_STATUS="N/A"
    KEY1_LAST_USED="N/A"
    KEY2_ID="N/A"
    KEY2_STATUS="N/A"
    KEY2_LAST_USED="N/A"

    KEY_COUNT=$(echo "$ACCESS_KEYS" | jq '.AccessKeyMetadata | length')

    if [[ "$KEY_COUNT" -ge 1 ]]; then
        KEY1_ID=$(echo "$ACCESS_KEYS" | jq -r '.AccessKeyMetadata[0].AccessKeyId')
        KEY1_STATUS=$(echo "$ACCESS_KEYS" | jq -r '.AccessKeyMetadata[0].Status')

        # Get last used date for key 1
        KEY1_USED=$(aws iam get-access-key-last-used --access-key-id "$KEY1_ID" --output json 2>/dev/null) || KEY1_USED='{}'
        KEY1_LAST_USED=$(echo "$KEY1_USED" | jq -r '.AccessKeyLastUsed.LastUsedDate // "Never"')
    fi

    if [[ "$KEY_COUNT" -ge 2 ]]; then
        KEY2_ID=$(echo "$ACCESS_KEYS" | jq -r '.AccessKeyMetadata[1].AccessKeyId')
        KEY2_STATUS=$(echo "$ACCESS_KEYS" | jq -r '.AccessKeyMetadata[1].Status')

        # Get last used date for key 2
        KEY2_USED=$(aws iam get-access-key-last-used --access-key-id "$KEY2_ID" --output json 2>/dev/null) || KEY2_USED='{}'
        KEY2_LAST_USED=$(echo "$KEY2_USED" | jq -r '.AccessKeyLastUsed.LastUsedDate // "Never"')
    fi

    # --- Get MFA Status ---
    MFA_DEVICES=$(aws iam list-mfa-devices --user-name "$USERNAME" --output json 2>/dev/null) || MFA_DEVICES='{"MFADevices":[]}'
    MFA_COUNT=$(echo "$MFA_DEVICES" | jq '.MFADevices | length')

    if [[ "$MFA_COUNT" -gt 0 ]]; then
        MFA_ENABLED="Yes"
    else
        MFA_ENABLED="No"
    fi

    # --- Write CSV row ---
    printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$USERNAME" \
        "$USERID" \
        "$CREATE_DATE" \
        "$PASSWORD_LAST_USED" \
        "$KEY1_ID" \
        "$KEY1_STATUS" \
        "$KEY1_LAST_USED" \
        "$KEY2_ID" \
        "$KEY2_STATUS" \
        "$KEY2_LAST_USED" \
        "$MFA_ENABLED" >> "$OUTPUT_FILE"
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

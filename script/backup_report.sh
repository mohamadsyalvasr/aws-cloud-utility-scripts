#!/bin/bash
# backup_report.sh
# Gathers an inventory report on AWS Backup vaults and protected resources.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_VAULTS="${OUTPUT_DIR}/backup_vaults_report.csv"
OUTPUT_FILE_PLANS="${OUTPUT_DIR}/backup_plans_report.csv"

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

This script generates two CSV files:
  1. backup_vaults_report.csv - Backup Vaults inventory
  2. backup_plans_report.csv  - Backup Plans inventory
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
mkdir -p "$(dirname "$OUTPUT_FILE_VAULTS")"

# =========================================================================
# PART 1: Backup Vaults
# =========================================================================
log "✍️ [Part 1] Generating Backup Vaults report..."
printf '"Vault Name","ARN","Recovery Points","Encryption Key ARN","Creation Date","Region"\n' > "$OUTPUT_FILE_VAULTS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Vaults)"

    VAULTS_DATA=$(aws backup list-backup-vaults --region "$region" --output json --no-paginate 2>/dev/null || echo '{"BackupVaultList":[]}')

    VAULT_COUNT=$(echo "$VAULTS_DATA" | jq '.BackupVaultList | length')

    if [[ "$VAULT_COUNT" -eq 0 ]]; then
        log "  [Backup] No vaults found."
    else
        log "  [Backup] Found $VAULT_COUNT vaults."
        echo "$VAULTS_DATA" | jq -c '.BackupVaultList[]' | while read -r vault; do
            VAULT_NAME=$(echo "$vault" | jq -r '.BackupVaultName // "N/A"')
            VAULT_ARN=$(echo "$vault" | jq -r '.BackupVaultArn // "N/A"')
            RECOVERY_POINTS=$(echo "$vault" | jq -r '.NumberOfRecoveryPoints // 0')
            ENCRYPTION_KEY=$(echo "$vault" | jq -r '.EncryptionKeyArn // "N/A"')
            CREATED=$(echo "$vault" | jq -r '.CreationDate // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$VAULT_NAME" \
                "$VAULT_ARN" \
                "$RECOVERY_POINTS" \
                "$ENCRYPTION_KEY" \
                "$CREATED" \
                "$region" >> "$OUTPUT_FILE_VAULTS"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ [Part 1] Backup Vaults report saved to: $OUTPUT_FILE_VAULTS"

# =========================================================================
# PART 2: Backup Plans
# =========================================================================
log "✍️ [Part 2] Generating Backup Plans report..."
printf '"Plan Name","Plan ID","ARN","Version ID","Creation Date","Last Execution Date","Region"\n' > "$OUTPUT_FILE_PLANS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Plans)"

    PLANS_DATA=$(aws backup list-backup-plans --region "$region" --output json --no-paginate 2>/dev/null || echo '{"BackupPlansList":[]}')

    PLAN_COUNT=$(echo "$PLANS_DATA" | jq '.BackupPlansList | length')

    if [[ "$PLAN_COUNT" -eq 0 ]]; then
        log "  [Backup] No backup plans found."
    else
        log "  [Backup] Found $PLAN_COUNT backup plans."
        echo "$PLANS_DATA" | jq -c '.BackupPlansList[]' | while read -r plan; do
            PLAN_NAME=$(echo "$plan" | jq -r '.BackupPlanName // "N/A"')
            PLAN_ID=$(echo "$plan" | jq -r '.BackupPlanId // "N/A"')
            PLAN_ARN=$(echo "$plan" | jq -r '.BackupPlanArn // "N/A"')
            VERSION_ID=$(echo "$plan" | jq -r '.VersionId // "N/A"')
            CREATED=$(echo "$plan" | jq -r '.CreationDate // "N/A"')
            LAST_EXEC=$(echo "$plan" | jq -r '.LastExecutionDate // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
                "$PLAN_NAME" \
                "$PLAN_ID" \
                "$PLAN_ARN" \
                "$VERSION_ID" \
                "$CREATED" \
                "$LAST_EXEC" \
                "$region" >> "$OUTPUT_FILE_PLANS"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ [Part 2] Backup Plans report saved to: $OUTPUT_FILE_PLANS"
log "✅ DONE. AWS Backup reports generated."

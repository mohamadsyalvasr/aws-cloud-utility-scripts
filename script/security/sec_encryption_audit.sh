#!/bin/bash
# sec_encryption_audit.sh
# Encryption Audit - Always runs manually (not covered by Trusted Advisor).
# Checks: Unencrypted EBS volumes, unencrypted RDS instances, KMS key rotation.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_encryption_audit.csv"
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

# --- Main ---
log "📊 Encryption Audit"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

FINDING_COUNT=0
REGION_COUNT=${#REGIONS[@]}
REGION_IDX=0

for region in "${REGIONS[@]}"; do
    REGION_IDX=$((REGION_IDX + 1))
    log "  [$REGION_IDX/$REGION_COUNT] Processing region: \033[1;33m$region\033[0m"

    # =========================================================================
    # 1. Check unencrypted EBS volumes
    # =========================================================================
    log "    [1/3] Checking for unencrypted EBS volumes..."
    set +e
    UNENC_VOLUMES=$(aws ec2 describe-volumes --region "$region" \
        --filters "Name=encrypted,Values=false" \
        --query 'Volumes[*].[VolumeId,Size,VolumeType]' --output json 2>/dev/null)
    EBS_EXIT=$?
    set -e

    if [[ $EBS_EXIT -ne 0 ]]; then
        log "      ⚠️ Could not check EBS volumes in $region. Skipping."
    else
        EBS_COUNT=$(echo "$UNENC_VOLUMES" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$EBS_COUNT" -gt 0 ]]; then
            log "      Found $EBS_COUNT unencrypted volume(s)"
            for i in $(seq 0 $((EBS_COUNT - 1))); do
                VOL_ID=$(echo "$UNENC_VOLUMES" | jq -r ".[$i][0]")
                VOL_SIZE=$(echo "$UNENC_VOLUMES" | jq -r ".[$i][1]")
                VOL_TYPE=$(echo "$UNENC_VOLUMES" | jq -r ".[$i][2]")

                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "EBS volume not encrypted" \
                    "$VOL_ID" \
                    "Volume $VOL_ID ($VOL_TYPE, ${VOL_SIZE}GiB) is not encrypted at rest" \
                    "High" \
                    "Create encrypted snapshot and replace volume" \
                    "$region" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
            done
        else
            log "      ✅ All EBS volumes encrypted"
        fi
    fi

    # =========================================================================
    # 2. Check unencrypted RDS instances
    # =========================================================================
    log "    [2/3] Checking for unencrypted RDS instances..."
    set +e
    RDS_INSTANCES=$(aws rds describe-db-instances --region "$region" \
        --query 'DBInstances[?StorageEncrypted==`false`].[DBInstanceIdentifier,DBInstanceClass,Engine]' \
        --output json 2>/dev/null)
    RDS_EXIT=$?
    set -e

    if [[ $RDS_EXIT -ne 0 ]]; then
        log "      ⚠️ Could not check RDS instances in $region. Skipping."
    else
        RDS_COUNT=$(echo "$RDS_INSTANCES" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$RDS_COUNT" -gt 0 ]]; then
            log "      Found $RDS_COUNT unencrypted RDS instance(s)"
            for i in $(seq 0 $((RDS_COUNT - 1))); do
                DB_ID=$(echo "$RDS_INSTANCES" | jq -r ".[$i][0]")
                DB_CLASS=$(echo "$RDS_INSTANCES" | jq -r ".[$i][1]")
                DB_ENGINE=$(echo "$RDS_INSTANCES" | jq -r ".[$i][2]")

                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "RDS instance not encrypted" \
                    "$DB_ID" \
                    "RDS instance $DB_ID ($DB_ENGINE, $DB_CLASS) storage is not encrypted" \
                    "High" \
                    "Create encrypted snapshot and restore to enable encryption" \
                    "$region" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
            done
        else
            log "      ✅ All RDS instances encrypted"
        fi
    fi

    # =========================================================================
    # 3. Check KMS key rotation (customer-managed keys only)
    # =========================================================================
    log "    [3/3] Checking KMS key rotation..."
    set +e
    KMS_KEYS=$(aws kms list-keys --region "$region" --query 'Keys[*].KeyId' --output json 2>/dev/null)
    KMS_EXIT=$?
    set -e

    if [[ $KMS_EXIT -ne 0 ]]; then
        log "      ⚠️ Could not list KMS keys in $region. Skipping."
    else
        KEY_COUNT=$(echo "$KMS_KEYS" | jq 'length' 2>/dev/null || echo "0")
        if [[ "$KEY_COUNT" -gt 0 ]]; then
            CHECKED=0
            for i in $(seq 0 $((KEY_COUNT - 1))); do
                KEY_ID=$(echo "$KMS_KEYS" | jq -r ".[$i]")

                # Get key metadata to check if customer-managed
                set +e
                KEY_META=$(aws kms describe-key --region "$region" --key-id "$KEY_ID" --output json 2>/dev/null)
                set -e

                if [[ -z "$KEY_META" ]]; then
                    continue
                fi

                KEY_MANAGER=$(echo "$KEY_META" | jq -r '.KeyMetadata.KeyManager // "AWS"')
                KEY_STATE=$(echo "$KEY_META" | jq -r '.KeyMetadata.KeyState // "Disabled"')

                # Skip AWS-managed keys and non-enabled keys
                if [[ "$KEY_MANAGER" != "CUSTOMER" ]] || [[ "$KEY_STATE" != "Enabled" ]]; then
                    continue
                fi

                CHECKED=$((CHECKED + 1))

                # Check rotation status
                set +e
                ROTATION=$(aws kms get-key-rotation-status --region "$region" --key-id "$KEY_ID" --output json 2>/dev/null)
                ROTATION_EXIT=$?
                set -e

                if [[ $ROTATION_EXIT -eq 0 ]]; then
                    IS_ROTATING=$(echo "$ROTATION" | jq -r '.KeyRotationEnabled // false')
                    if [[ "$IS_ROTATING" != "true" ]]; then
                        KEY_ARN=$(echo "$KEY_META" | jq -r '.KeyMetadata.Arn')
                        printf '"%s","%s","%s","%s","%s","%s"\n' \
                            "KMS key rotation not enabled" \
                            "$KEY_ARN" \
                            "Customer-managed KMS key $KEY_ID does not have automatic rotation enabled" \
                            "Medium" \
                            "Enable automatic key rotation for customer-managed KMS keys" \
                            "$region" >> "$OUTPUT_FILE"
                        FINDING_COUNT=$((FINDING_COUNT + 1))
                    fi
                fi
            done
            log "      Checked $CHECKED customer-managed key(s)"
        else
            log "      No KMS keys found"
        fi
    fi

    log "    Region $region complete."
done

log "✅ DONE. Encryption audit complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

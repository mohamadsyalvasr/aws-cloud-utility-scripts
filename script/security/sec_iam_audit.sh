#!/bin/bash
# sec_iam_audit.sh
# IAM Security Audit - Manual fallback for IAM security checks.
# Checks: MFA, AdministratorAccess, stale access keys, root usage, password policy.
# Skips if Trusted Advisor already covered IAM category.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_iam_audit.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
Options:
  -r <regions>   Not used (IAM is global). Accepted for framework compatibility.
  -f <filename>  Custom output filename.
  -h             Show this help message.
EOF
    exit 1
}

while getopts "r:f:h" opt; do
    case "$opt" in
        r) : ;; # Accepted but not used
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
MY_CATEGORY="IAM"

if [[ -f "$COVERAGE_FILE" ]] && grep -q "^${MY_CATEGORY}$" "$COVERAGE_FILE"; then
    log "⏭️ Skipping ${MY_CATEGORY} audit — covered by Trusted Advisor"
    printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"
    exit 0
fi

# --- Main ---
log "📊 IAM Security Audit (Manual Fallback)"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Finding","Resource","Detail","Severity","Recommendation","Region"\n' > "$OUTPUT_FILE"

FINDING_COUNT=0

# =========================================================================
# 1. Check IAM users without MFA
# =========================================================================
log "  [1/5] Checking IAM users for MFA..."
set +e
USERS_JSON=$(aws iam list-users --query 'Users[*].[UserName,Arn]' --output json 2>/dev/null)
USERS_EXIT=$?
set -e

if [[ $USERS_EXIT -eq 0 ]] && [[ -n "$USERS_JSON" ]] && [[ "$USERS_JSON" != "[]" ]]; then
    USER_COUNT=$(echo "$USERS_JSON" | jq 'length')
    log "    Found $USER_COUNT user(s)"

    for i in $(seq 0 $((USER_COUNT - 1))); do
        USERNAME=$(echo "$USERS_JSON" | jq -r ".[$i][0]")
        USER_ARN=$(echo "$USERS_JSON" | jq -r ".[$i][1]")

        # Check MFA devices
        MFA_DEVICES=$(aws iam list-mfa-devices --user-name "$USERNAME" --query 'MFADevices' --output json 2>/dev/null) || MFA_DEVICES="[]"
        MFA_COUNT=$(echo "$MFA_DEVICES" | jq 'length')

        if [[ "$MFA_COUNT" -eq 0 ]]; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "No MFA enabled" \
                "$USER_ARN" \
                "User $USERNAME has no MFA device configured" \
                "High" \
                "Enable MFA for all IAM users" \
                "Global" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        fi
    done
else
    log "    ⚠️ Could not list IAM users. Skipping MFA check."
fi

# =========================================================================
# 2. Check IAM users with AdministratorAccess attached
# =========================================================================
log "  [2/5] Checking for AdministratorAccess attached to users..."

if [[ $USERS_EXIT -eq 0 ]] && [[ -n "$USERS_JSON" ]] && [[ "$USERS_JSON" != "[]" ]]; then
    for i in $(seq 0 $((USER_COUNT - 1))); do
        USERNAME=$(echo "$USERS_JSON" | jq -r ".[$i][0]")
        USER_ARN=$(echo "$USERS_JSON" | jq -r ".[$i][1]")

        ATTACHED_POLICIES=$(aws iam list-attached-user-policies --user-name "$USERNAME" \
            --query 'AttachedPolicies[*].PolicyName' --output json 2>/dev/null) || ATTACHED_POLICIES="[]"

        if echo "$ATTACHED_POLICIES" | jq -e '.[] | select(. == "AdministratorAccess")' &>/dev/null; then
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "AdministratorAccess attached to user" \
                "$USER_ARN" \
                "User $USERNAME has AdministratorAccess policy directly attached" \
                "Critical" \
                "Use groups or roles instead of attaching admin policies to users" \
                "Global" >> "$OUTPUT_FILE"
            FINDING_COUNT=$((FINDING_COUNT + 1))
        fi
    done
fi

# =========================================================================
# 3. Check access keys unused for 90+ days
# =========================================================================
log "  [3/5] Checking for stale access keys (90+ days unused)..."

if [[ $USERS_EXIT -eq 0 ]] && [[ -n "$USERS_JSON" ]] && [[ "$USERS_JSON" != "[]" ]]; then
    NINETY_DAYS_AGO=$(date -u -d "90 days ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")

    for i in $(seq 0 $((USER_COUNT - 1))); do
        USERNAME=$(echo "$USERS_JSON" | jq -r ".[$i][0]")
        USER_ARN=$(echo "$USERS_JSON" | jq -r ".[$i][1]")

        ACCESS_KEYS=$(aws iam list-access-keys --user-name "$USERNAME" \
            --query 'AccessKeyMetadata[*].[AccessKeyId,Status]' --output json 2>/dev/null) || ACCESS_KEYS="[]"

        KEY_COUNT=$(echo "$ACCESS_KEYS" | jq 'length')
        for k in $(seq 0 $((KEY_COUNT - 1))); do
            KEY_ID=$(echo "$ACCESS_KEYS" | jq -r ".[$k][0]")
            KEY_STATUS=$(echo "$ACCESS_KEYS" | jq -r ".[$k][1]")

            if [[ "$KEY_STATUS" != "Active" ]]; then
                continue
            fi

            LAST_USED=$(aws iam get-access-key-last-used --access-key-id "$KEY_ID" \
                --query 'AccessKeyLastUsed.LastUsedDate' --output text 2>/dev/null) || LAST_USED="N/A"

            if [[ "$LAST_USED" == "N/A" ]] || [[ "$LAST_USED" == "None" ]] || [[ -z "$LAST_USED" ]]; then
                # Key never used — report as stale
                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "Access key unused for 90+ days" \
                    "$USER_ARN" \
                    "Access key $KEY_ID for user $USERNAME has never been used" \
                    "Medium" \
                    "Rotate or delete unused access keys" \
                    "Global" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
            elif [[ -n "$NINETY_DAYS_AGO" ]]; then
                if [[ "$LAST_USED" < "$NINETY_DAYS_AGO" ]]; then
                    printf '"%s","%s","%s","%s","%s","%s"\n' \
                        "Access key unused for 90+ days" \
                        "$USER_ARN" \
                        "Access key $KEY_ID for user $USERNAME last used $LAST_USED" \
                        "Medium" \
                        "Rotate or delete unused access keys" \
                        "Global" >> "$OUTPUT_FILE"
                    FINDING_COUNT=$((FINDING_COUNT + 1))
                fi
            fi
        done
    done
fi

# =========================================================================
# 4. Check root account usage within last 30 days
# =========================================================================
log "  [4/5] Checking root account usage..."
set +e
CRED_REPORT=$(aws iam generate-credential-report --output text 2>/dev/null)
sleep 2
CRED_REPORT_CSV=$(aws iam get-credential-report --query 'Content' --output text 2>/dev/null | base64 -d 2>/dev/null || echo "")
set -e

if [[ -n "$CRED_REPORT_CSV" ]]; then
    ROOT_LINE=$(echo "$CRED_REPORT_CSV" | grep "<root_account>" 2>/dev/null || echo "")
    if [[ -n "$ROOT_LINE" ]]; then
        # password_last_used is field 5 (0-indexed: 4)
        ROOT_LAST_USED=$(echo "$ROOT_LINE" | cut -d',' -f5)
        if [[ -n "$ROOT_LAST_USED" ]] && [[ "$ROOT_LAST_USED" != "not_supported" ]] && [[ "$ROOT_LAST_USED" != "no_information" ]] && [[ "$ROOT_LAST_USED" != "N/A" ]]; then
            THIRTY_DAYS_AGO=$(date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-30d +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")
            if [[ -n "$THIRTY_DAYS_AGO" ]] && [[ "$ROOT_LAST_USED" > "$THIRTY_DAYS_AGO" ]]; then
                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "Root account used recently" \
                    "arn:aws:iam::root" \
                    "Root account last used: $ROOT_LAST_USED" \
                    "Critical" \
                    "Avoid using root account; use IAM users with least privilege" \
                    "Global" >> "$OUTPUT_FILE"
                FINDING_COUNT=$((FINDING_COUNT + 1))
            fi
        fi
    fi
else
    log "    ⚠️ Could not retrieve credential report. Skipping root usage check."
fi

# =========================================================================
# 5. Check password policy
# =========================================================================
log "  [5/5] Checking account password policy..."
set +e
PASS_POLICY=$(aws iam get-account-password-policy --output json 2>/dev/null)
PASS_EXIT=$?
set -e

if [[ $PASS_EXIT -eq 0 ]] && [[ -n "$PASS_POLICY" ]]; then
    MIN_LENGTH=$(echo "$PASS_POLICY" | jq -r '.PasswordPolicy.MinimumPasswordLength // 0')
    REQUIRE_SYMBOLS=$(echo "$PASS_POLICY" | jq -r '.PasswordPolicy.RequireSymbols // false')
    REQUIRE_NUMBERS=$(echo "$PASS_POLICY" | jq -r '.PasswordPolicy.RequireNumbers // false')
    REQUIRE_UPPER=$(echo "$PASS_POLICY" | jq -r '.PasswordPolicy.RequireUppercaseCharacters // false')
    REQUIRE_LOWER=$(echo "$PASS_POLICY" | jq -r '.PasswordPolicy.RequireLowercaseCharacters // false')
    MAX_AGE=$(echo "$PASS_POLICY" | jq -r '.PasswordPolicy.MaxPasswordAge // 0')

    if [[ "$MIN_LENGTH" -lt 14 ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Password policy non-compliant" \
            "PasswordPolicy" \
            "Minimum password length is $MIN_LENGTH (should be >= 14)" \
            "Medium" \
            "Set minimum password length to at least 14 characters" \
            "Global" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    if [[ "$REQUIRE_SYMBOLS" != "true" ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Password policy non-compliant" \
            "PasswordPolicy" \
            "Password policy does not require symbols" \
            "Medium" \
            "Enable RequireSymbols in password policy" \
            "Global" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    if [[ "$REQUIRE_NUMBERS" != "true" ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Password policy non-compliant" \
            "PasswordPolicy" \
            "Password policy does not require numbers" \
            "Medium" \
            "Enable RequireNumbers in password policy" \
            "Global" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    if [[ "$REQUIRE_UPPER" != "true" ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Password policy non-compliant" \
            "PasswordPolicy" \
            "Password policy does not require uppercase characters" \
            "Medium" \
            "Enable RequireUppercaseCharacters in password policy" \
            "Global" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    if [[ "$REQUIRE_LOWER" != "true" ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Password policy non-compliant" \
            "PasswordPolicy" \
            "Password policy does not require lowercase characters" \
            "Medium" \
            "Enable RequireLowercaseCharacters in password policy" \
            "Global" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi

    if [[ "$MAX_AGE" -eq 0 ]] || [[ "$MAX_AGE" -gt 90 ]]; then
        printf '"%s","%s","%s","%s","%s","%s"\n' \
            "Password policy non-compliant" \
            "PasswordPolicy" \
            "Max password age is ${MAX_AGE} days (should be <= 90)" \
            "Medium" \
            "Set MaxPasswordAge to 90 days or less" \
            "Global" >> "$OUTPUT_FILE"
        FINDING_COUNT=$((FINDING_COUNT + 1))
    fi
else
    log "    ⚠️ No password policy configured or unable to retrieve."
    printf '"%s","%s","%s","%s","%s","%s"\n' \
        "No password policy configured" \
        "PasswordPolicy" \
        "Account does not have a custom password policy" \
        "Medium" \
        "Configure a strong password policy for the account" \
        "Global" >> "$OUTPUT_FILE"
    FINDING_COUNT=$((FINDING_COUNT + 1))
fi

log "✅ DONE. IAM audit complete. Found $FINDING_COUNT finding(s)."
log "   Report saved to: $OUTPUT_FILE"

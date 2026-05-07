#!/bin/bash
# multi_account_runner.sh
# Standalone wrapper that orchestrates report generation across multiple AWS accounts.
# Discovers accounts (from file or Organizations), validates role assumption,
# then loops through each account running main_report_runner.sh.

set -euo pipefail

# --- Load Modules ---
source ./lib/logger.sh

# --- Dependency Check ---
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

# --- Default Configuration ---
SOURCE="file"
ROLE_NAME=""
NO_SUMMARY=false
START_DATE=""
END_DATE=""
PASS_THROUGH_ARGS=()

# Account arrays
ACCOUNT_IDS=()
ACCOUNT_ROLES=()
ACCOUNT_ALIASES=()
ACCOUNT_STATUS=()
ACCOUNT_ERRORS=()

# --- Functions ---

usage() {
    cat <<EOF
Usage: $0 --source <file|organizations> --role <role_name> -b <start_date> -e <end_date> [options]

Multi-account report runner. Generates reports across multiple AWS accounts
by assuming a cross-account IAM role in each target account.

Required:
  -b, --begin <date>       Start date (YYYY-MM-DD) for reports
  -e, --end <date>         End date (YYYY-MM-DD) for reports

Options:
  --source <method>        Account discovery method: file (default) or organizations
  --role <role_name>       IAM role name to assume (required for --source organizations;
                           for --source file, role is read from accounts.conf)
  -m, --mode <mode>        Run mode: all, inventory, optimize, security (passed through)
  -r, --regions <regions>  AWS regions (passed through)
  --no-summary             Skip cross-account summary CSV generation
  -h, --help               Show this help message

Pass-through flags (forwarded to main_report_runner.sh):
  -s, --sum-ebs            Sum EBS volumes
  -f, --filename <name>    Custom filename

Examples:
  $0 -b 2025-01-01 -e 2025-01-31
  $0 --source organizations --role CrossAccountReportRole -b 2025-01-01 -e 2025-01-31
  $0 --source file -b 2025-01-01 -e 2025-01-31 -m optimize
  $0 -b 2025-01-01 -e 2025-01-31 --no-summary

Prerequisites:
  See docs/multi-account-setup.md for IAM role configuration.
EOF
    exit 0
}

print_prerequisite_warning() {
    log "╔══════════════════════════════════════════════════════════════════╗"
    log "║  MULTI-ACCOUNT MODE                                            ║"
    log "║                                                                ║"
    log "║  Each target account requires a cross-account IAM role.        ║"
    log "║  See: docs/multi-account-setup.md                              ║"
    log "╚══════════════════════════════════════════════════════════════════╝"
}

load_accounts_from_file() {
    local config_file="accounts.conf"
    if [[ ! -f "$config_file" ]]; then
        log_error "Account configuration file not found: $config_file"
        log_error "Create accounts.conf with target accounts. See docs/multi-account-setup.md"
        exit 1
    fi

    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        # Parse pipe-delimited fields
        IFS='|' read -r acct_id acct_role acct_alias <<< "$line"

        # Validate minimum fields
        if [[ -z "${acct_id:-}" || -z "${acct_role:-}" ]]; then
            log_error "Line $line_num: Invalid format (need at least Account_ID|Role_Name): $line"
            continue
        fi

        # Trim whitespace
        acct_id=$(echo "$acct_id" | tr -d '[:space:]')
        acct_role=$(echo "$acct_role" | tr -d '[:space:]')
        acct_alias=$(echo "${acct_alias:-}" | tr -d '[:space:]')

        ACCOUNT_IDS+=("$acct_id")
        ACCOUNT_ROLES+=("$acct_role")
        ACCOUNT_ALIASES+=("${acct_alias:-$acct_id}")
    done < "$config_file"

    if [[ ${#ACCOUNT_IDS[@]} -eq 0 ]]; then
        log_error "No valid accounts found in $config_file"
        log_error "Add account entries in format: Account_ID|Role_Name|Account_Alias"
        exit 1
    fi

    log_success "Loaded ${#ACCOUNT_IDS[@]} account(s) from $config_file"
}

load_accounts_from_organizations() {
    if [[ -z "$ROLE_NAME" ]]; then
        log_error "--role is required when using --source organizations"
        exit 1
    fi

    log "Querying AWS Organizations for active accounts..."

    local current_account
    current_account=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null) || {
        log_error "Failed to get current account ID via sts get-caller-identity"
        exit 1
    }

    local accounts_json
    accounts_json=$(aws organizations list-accounts --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' --output json 2>&1) || {
        log_error "Failed to list accounts from AWS Organizations."
        log_error "Ensure you are running from the management account or a delegated admin."
        log_error "Error: $accounts_json"
        exit 1
    }

    local count
    count=$(echo "$accounts_json" | jq 'length')

    for (( i=0; i<count; i++ )); do
        local acct_id acct_name
        acct_id=$(echo "$accounts_json" | jq -r ".[$i][0]")
        acct_name=$(echo "$accounts_json" | jq -r ".[$i][1]")

        # Skip current account
        if [[ "$acct_id" == "$current_account" ]]; then
            log "Skipping current account: $acct_id ($acct_name)"
            continue
        fi

        ACCOUNT_IDS+=("$acct_id")
        ACCOUNT_ROLES+=("$ROLE_NAME")
        ACCOUNT_ALIASES+=("${acct_name:-$acct_id}")
    done

    if [[ ${#ACCOUNT_IDS[@]} -eq 0 ]]; then
        log_error "No target accounts found in AWS Organizations (excluding current account)"
        exit 1
    fi

    log_success "Found ${#ACCOUNT_IDS[@]} target account(s) from Organizations"
}

dry_run_check() {
    log_start "🔐 Dry-run: validating role assumption for ${#ACCOUNT_IDS[@]} account(s)..."

    local passed=0
    local failed=0

    for (( i=0; i<${#ACCOUNT_IDS[@]}; i++ )); do
        local acct_id="${ACCOUNT_IDS[$i]}"
        local acct_role="${ACCOUNT_ROLES[$i]}"
        local acct_alias="${ACCOUNT_ALIASES[$i]}"
        local role_arn="arn:aws:iam::${acct_id}:role/${acct_role}"

        if aws sts assume-role \
            --role-arn "$role_arn" \
            --role-session-name "dry-run-check" \
            --duration-seconds 900 \
            --output json &>/dev/null; then
            ACCOUNT_STATUS+=("OK")
            ACCOUNT_ERRORS+=("")
            passed=$((passed + 1))
            log "  ✅ $acct_id ($acct_alias) — OK"
        else
            ACCOUNT_STATUS+=("FAILED")
            ACCOUNT_ERRORS+=("AssumeRole failed")
            failed=$((failed + 1))
            log "  ❌ $acct_id ($acct_alias) — FAILED"
        fi
    done

    log ""
    log "Dry-run results: $passed OK, $failed FAILED"

    if [[ $passed -eq 0 ]]; then
        log_error "All accounts failed dry-run. Check IAM role configuration."
        log_error "See docs/multi-account-setup.md for setup instructions."
        exit 1
    fi

    if [[ $failed -gt 0 ]]; then
        log "⚠️  Some accounts failed. Failed accounts will be skipped during execution."
        log "Failed accounts:"
        for (( i=0; i<${#ACCOUNT_IDS[@]}; i++ )); do
            if [[ "${ACCOUNT_STATUS[$i]}" == "FAILED" ]]; then
                log "  - ${ACCOUNT_IDS[$i]} (${ACCOUNT_ALIASES[$i]})"
            fi
        done
    fi
}

assume_role() {
    local acct_id="$1"
    local acct_role="$2"
    local role_arn="arn:aws:iam::${acct_id}:role/${acct_role}"

    local creds
    creds=$(aws sts assume-role \
        --role-arn "$role_arn" \
        --role-session-name "multi-account-report" \
        --duration-seconds 3600 \
        --output json)

    export AWS_ACCESS_KEY_ID=$(echo "$creds" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$creds" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$creds" | jq -r '.Credentials.SessionToken')
}

cleanup_credentials() {
    unset AWS_ACCESS_KEY_ID 2>/dev/null || true
    unset AWS_SECRET_ACCESS_KEY 2>/dev/null || true
    unset AWS_SESSION_TOKEN 2>/dev/null || true
}

generate_summary() {
    local summary_file="${BASE_OUTPUT_DIR}/cross_account_summary.csv"

    echo '"Account ID","Account Alias","Status","Report Directory","Error"' > "$summary_file"

    for (( i=0; i<${#ACCOUNT_IDS[@]}; i++ )); do
        local acct_id="${ACCOUNT_IDS[$i]}"
        local acct_alias="${ACCOUNT_ALIASES[$i]}"
        local status="${EXECUTION_STATUS[$i]:-Skipped}"
        local acct_dir="${EXECUTION_DIRS[$i]:-}"
        local error="${EXECUTION_ERRORS[$i]:-}"

        echo "\"${acct_id}\",\"${acct_alias}\",\"${status}\",\"${acct_dir}\",\"${error}\"" >> "$summary_file"
    done

    log_success "Cross-account summary written to: $summary_file"
}

# --- Trap for credential cleanup ---
trap cleanup_credentials EXIT INT TERM

# --- Parse CLI Arguments ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --source)     shift; SOURCE="$1" ;;
        --role)       shift; ROLE_NAME="$1" ;;
        --no-summary) NO_SUMMARY=true ;;
        -b|--begin)   shift; START_DATE="$1"; PASS_THROUGH_ARGS+=("-b" "$1") ;;
        -e|--end)     shift; END_DATE="$1"; PASS_THROUGH_ARGS+=("-e" "$1") ;;
        -m|--mode)    shift; PASS_THROUGH_ARGS+=("-m" "$1") ;;
        -r|--regions) shift; PASS_THROUGH_ARGS+=("-r" "$1") ;;
        -s|--sum-ebs) PASS_THROUGH_ARGS+=("-s") ;;
        -f|--filename) shift; PASS_THROUGH_ARGS+=("-f" "$1") ;;
        -h|--help)    usage ;;
        *)            log_error "Unknown option: $1"; usage ;;
    esac
    shift
done

# --- Validate Required Arguments ---
if [[ -z "$START_DATE" || -z "$END_DATE" ]]; then
    log_error "Missing required arguments: -b <start_date> and -e <end_date>"
    echo ""
    usage
fi

if [[ "$SOURCE" == "organizations" && -z "$ROLE_NAME" ]]; then
    log_error "--role is required when using --source organizations"
    exit 1
fi

# --- Print Prerequisite Warning ---
print_prerequisite_warning

# --- Load Accounts ---
log_start "📋 Loading accounts (source: $SOURCE)..."
if [[ "$SOURCE" == "file" ]]; then
    load_accounts_from_file
elif [[ "$SOURCE" == "organizations" ]]; then
    load_accounts_from_organizations
else
    log_error "Invalid source: $SOURCE (must be 'file' or 'organizations')"
    exit 1
fi

# --- Dry-Run Validation ---
dry_run_check

# --- Setup Output Directory ---
BASE_OUTPUT_DIR="export/multi-account-${END_DATE}"
mkdir -p "$BASE_OUTPUT_DIR"

# --- Execution Tracking ---
EXECUTION_STATUS=()
EXECUTION_DIRS=()
EXECUTION_ERRORS=()
TOTAL_ACCOUNTS=${#ACCOUNT_IDS[@]}
PROCESSED=0
SUCCESS_COUNT=0
FAILED_COUNT=0

# --- Main Execution Loop ---
log_start "🚀 Starting multi-account report generation..."
log ""

for (( i=0; i<TOTAL_ACCOUNTS; i++ )); do
    local_acct_id="${ACCOUNT_IDS[$i]}"
    local_acct_role="${ACCOUNT_ROLES[$i]}"
    local_acct_alias="${ACCOUNT_ALIASES[$i]}"
    local_acct_status="${ACCOUNT_STATUS[$i]}"

    PROCESSED=$((PROCESSED + 1))

    # Skip accounts that failed dry-run
    if [[ "$local_acct_status" == "FAILED" ]]; then
        log "[$PROCESSED/$TOTAL_ACCOUNTS] Skipping $local_acct_id ($local_acct_alias) — failed dry-run"
        EXECUTION_STATUS+=("Skipped")
        EXECUTION_DIRS+=("")
        EXECUTION_ERRORS+=("Failed dry-run validation")
        FAILED_COUNT=$((FAILED_COUNT + 1))
        continue
    fi

    log "[$PROCESSED/$TOTAL_ACCOUNTS] Processing account: $local_acct_id ($local_acct_alias)"

    # Set per-account output directory
    local_output_dir="${BASE_OUTPUT_DIR}/${local_acct_id}_${local_acct_alias}"
    export OUTPUT_DIR="$local_output_dir"
    mkdir -p "$OUTPUT_DIR"

    # Assume role
    if ! assume_role "$local_acct_id" "$local_acct_role"; then
        log_error "  Failed to assume role in $local_acct_id"
        EXECUTION_STATUS+=("Failed")
        EXECUTION_DIRS+=("$local_output_dir")
        EXECUTION_ERRORS+=("AssumeRole failed during execution")
        FAILED_COUNT=$((FAILED_COUNT + 1))
        cleanup_credentials
        continue
    fi

    # Run reports
    if ./main_report_runner.sh "${PASS_THROUGH_ARGS[@]}" </dev/null; then
        log_success "  Reports completed for $local_acct_id ($local_acct_alias)"
        EXECUTION_STATUS+=("Success")
        EXECUTION_DIRS+=("$local_output_dir")
        EXECUTION_ERRORS+=("")
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        log_error "  Reports failed for $local_acct_id ($local_acct_alias)"
        EXECUTION_STATUS+=("Failed")
        EXECUTION_DIRS+=("$local_output_dir")
        EXECUTION_ERRORS+=("main_report_runner.sh exited with error")
        FAILED_COUNT=$((FAILED_COUNT + 1))
    fi

    # Cleanup credentials after each account
    cleanup_credentials
    log ""
done

# --- Generate Summary ---
if [[ "$NO_SUMMARY" == "false" ]]; then
    generate_summary
fi

# --- Final Summary ---
log ""
log "═══════════════════════════════════════════════════════"
log "  Multi-Account Report Generation Complete"
log "═══════════════════════════════════════════════════════"
log "  Total accounts:  $TOTAL_ACCOUNTS"
log "  Successful:      $SUCCESS_COUNT"
log "  Failed/Skipped:  $FAILED_COUNT"
log "  Output:          $BASE_OUTPUT_DIR/"
log "═══════════════════════════════════════════════════════"

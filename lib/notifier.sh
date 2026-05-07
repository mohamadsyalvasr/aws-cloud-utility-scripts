#!/bin/bash
# lib/notifier.sh
# Notification library for post-run summary delivery.
# Supports Slack (Block Kit), Microsoft Teams (Adaptive Card), and AWS SNS.
#
# Configuration via environment variables:
#   NOTIFY_SLACK=1, SLACK_WEBHOOK_URL=<url>
#   NOTIFY_TEAMS=1, TEAMS_WEBHOOK_URL=<url>
#   NOTIFY_SNS=1, SNS_TOPIC_ARN=<arn>
#
# This library NEVER fails — all errors are logged and execution continues.

# --- Internal Helper Functions ---

_notifier_extract_stats() {
    # Read RESULT_DIR status files to compute report statistics
    NOTIFIER_TOTAL_REPORTS=0
    NOTIFIER_SUCCESS_COUNT=0
    NOTIFIER_FAILED_COUNT=0

    if [[ -n "${RESULT_DIR:-}" && -d "${RESULT_DIR:-}" ]]; then
        NOTIFIER_TOTAL_REPORTS=$(find "$RESULT_DIR" -name "*.status" 2>/dev/null | wc -l | tr -d '[:space:]')
        NOTIFIER_SUCCESS_COUNT=$(grep -rl "^0$" "$RESULT_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')
        NOTIFIER_FAILED_COUNT=$((NOTIFIER_TOTAL_REPORTS - NOTIFIER_SUCCESS_COUNT))
    fi
}

_notifier_extract_savings() {
    # Extract total potential monthly savings from optimization summary
    local summary_file="${OUTPUT_DIR:-}/optimization_summary.csv"
    NOTIFIER_SAVINGS=""

    if [[ ! -f "$summary_file" ]]; then
        # Try alternate name
        summary_file=$(find "${OUTPUT_DIR:-}" -maxdepth 1 -name "opt_*summary*.csv" 2>/dev/null | head -1)
    fi

    if [[ -n "$summary_file" && -f "$summary_file" ]]; then
        # Look for a savings/total column
        NOTIFIER_SAVINGS=$(awk -F',' 'NR>1 {
            for(i=1;i<=NF;i++) {
                val=$i; gsub(/[" $,]/, "", val)
                if (val ~ /^[0-9]+\.?[0-9]*$/ && val+0 > 0) { sum += val }
            }
        } END { if(sum>0) printf "$%.2f", sum }' "$summary_file" 2>/dev/null || echo "")
    fi
}

_notifier_extract_security() {
    # Extract critical and high finding counts from security summary
    NOTIFIER_CRITICAL=""
    NOTIFIER_HIGH=""

    local summary_file="${OUTPUT_DIR:-}/sec_summary_report.csv"
    if [[ ! -f "$summary_file" ]]; then
        summary_file=$(find "${OUTPUT_DIR:-}" -maxdepth 1 -name "sec_*summary*.csv" 2>/dev/null | head -1)
    fi

    if [[ -n "$summary_file" && -f "$summary_file" ]]; then
        NOTIFIER_CRITICAL=$(awk -F',' 'tolower($0) ~ /critical/ { for(i=1;i<=NF;i++) { val=$i; gsub(/[" ]/, "", val); if(val ~ /^[0-9]+$/) { print val; exit } } }' "$summary_file" 2>/dev/null || echo "")
        NOTIFIER_HIGH=$(awk -F',' 'tolower($0) ~ /high/ { for(i=1;i<=NF;i++) { val=$i; gsub(/[" ]/, "", val); if(val ~ /^[0-9]+$/) { print val; exit } } }' "$summary_file" 2>/dev/null || echo "")
    fi
}

_notifier_extract_health_score() {
    # Extract overall health score from scorecard
    NOTIFIER_HEALTH_SCORE=""

    local scorecard_file
    scorecard_file=$(find "${OUTPUT_DIR:-}" -maxdepth 1 -name "scorecard_report.csv" 2>/dev/null | head -1)

    if [[ -n "$scorecard_file" && -f "$scorecard_file" ]]; then
        NOTIFIER_HEALTH_SCORE=$(awk -F',' 'tolower($0) ~ /health score/ {
            for(i=1;i<=NF;i++) {
                val=$i; gsub(/[" ]/, "", val)
                if(val ~ /^[0-9]+$/) { print val; exit }
            }
        }' "$scorecard_file" 2>/dev/null || echo "")
    fi
}

_notifier_get_account_info() {
    # Get AWS account info
    NOTIFIER_ACCOUNT_ID="${AWS_ACCOUNT_ID:-}"
    NOTIFIER_ACCOUNT_NAME="${AWS_ACCOUNT_NAME:-Unknown}"

    if [[ -z "$NOTIFIER_ACCOUNT_ID" ]]; then
        NOTIFIER_ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || echo "N/A")
    fi

    if [[ "$NOTIFIER_ACCOUNT_NAME" == "Unknown" ]]; then
        local aliases
        aliases=$(aws iam list-account-aliases --query 'AccountAliases[0]' --output text 2>/dev/null || echo "")
        if [[ -n "$aliases" && "$aliases" != "None" ]]; then
            NOTIFIER_ACCOUNT_NAME="$aliases"
        fi
    fi
}

# --- Channel Functions ---

send_slack_notification() {
    if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
        log_error "Slack notification enabled but SLACK_WEBHOOK_URL is empty"
        return 1
    fi

    local run_date="${YEAR:-$(date +%Y)}-${MONTH:-$(date +%m)}-${DAY:-$(date +%d)}"
    local mode="${RUN_MODE:-all}"

    # Build blocks JSON
    local blocks='[
        {"type":"header","text":{"type":"plain_text","text":"AWS Report Complete ✅"}},
        {"type":"section","fields":[
            {"type":"mrkdwn","text":"*Account:* '"${NOTIFIER_ACCOUNT_NAME}"' ('"${NOTIFIER_ACCOUNT_ID}"')"},
            {"type":"mrkdwn","text":"*Date:* '"${run_date}"'"},
            {"type":"mrkdwn","text":"*Mode:* '"${mode}"'"}
        ]},
        {"type":"section","fields":[
            {"type":"mrkdwn","text":"*Reports:* '"${NOTIFIER_SUCCESS_COUNT}"'/'"${NOTIFIER_TOTAL_REPORTS}"' passed"},
            {"type":"mrkdwn","text":"*Failed:* '"${NOTIFIER_FAILED_COUNT}"'"}
        ]},
        {"type":"section","text":{"type":"mrkdwn","text":"*Archive:* '"${ZIP_FILENAME:-N/A}"'"}}'

    # Conditional: savings
    if [[ -n "${NOTIFIER_SAVINGS:-}" ]]; then
        blocks="${blocks}"',
        {"type":"section","text":{"type":"mrkdwn","text":"💰 *Potential Savings:* '"${NOTIFIER_SAVINGS}"'/month"}}'
    fi

    # Conditional: security findings
    if [[ -n "${NOTIFIER_CRITICAL:-}" || -n "${NOTIFIER_HIGH:-}" ]]; then
        blocks="${blocks}"',
        {"type":"section","text":{"type":"mrkdwn","text":"🔒 *Security:* '"${NOTIFIER_CRITICAL:-0}"' Critical, '"${NOTIFIER_HIGH:-0}"' High"}}'
    fi

    # Conditional: health score
    if [[ -n "${NOTIFIER_HEALTH_SCORE:-}" ]]; then
        blocks="${blocks}"',
        {"type":"section","text":{"type":"mrkdwn","text":"🏥 *Health Score:* '"${NOTIFIER_HEALTH_SCORE}"'"}}'
    fi

    blocks="${blocks}]"

    local payload='{"blocks":'"${blocks}"'}'

    # POST to Slack
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$SLACK_WEBHOOK_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        log_success "Slack notification sent successfully"
        return 0
    else
        log_error "Slack notification failed (HTTP $http_code)"
        return 1
    fi
}

send_teams_notification() {
    if [[ -z "${TEAMS_WEBHOOK_URL:-}" ]]; then
        log_error "Teams notification enabled but TEAMS_WEBHOOK_URL is empty"
        return 1
    fi

    local run_date="${YEAR:-$(date +%Y)}-${MONTH:-$(date +%m)}-${DAY:-$(date +%d)}"
    local mode="${RUN_MODE:-all}"

    # Build facts
    local facts='[
        {"title":"Account","value":"'"${NOTIFIER_ACCOUNT_NAME}"' ('"${NOTIFIER_ACCOUNT_ID}"')"},
        {"title":"Date","value":"'"${run_date}"'"},
        {"title":"Mode","value":"'"${mode}"'"},
        {"title":"Reports","value":"'"${NOTIFIER_SUCCESS_COUNT}"'/'"${NOTIFIER_TOTAL_REPORTS}"' passed ('"${NOTIFIER_FAILED_COUNT}"' failed)"},
        {"title":"Archive","value":"'"${ZIP_FILENAME:-N/A}"'"}'

    # Conditional facts
    if [[ -n "${NOTIFIER_SAVINGS:-}" ]]; then
        facts="${facts}"',
        {"title":"Potential Savings","value":"'"${NOTIFIER_SAVINGS}"'/month"}'
    fi
    if [[ -n "${NOTIFIER_CRITICAL:-}" || -n "${NOTIFIER_HIGH:-}" ]]; then
        facts="${facts}"',
        {"title":"Security Findings","value":"'"${NOTIFIER_CRITICAL:-0}"' Critical, '"${NOTIFIER_HIGH:-0}"' High"}'
    fi
    if [[ -n "${NOTIFIER_HEALTH_SCORE:-}" ]]; then
        facts="${facts}"',
        {"title":"Health Score","value":"'"${NOTIFIER_HEALTH_SCORE}"'"}'
    fi

    facts="${facts}]"

    local payload='{
        "type":"message",
        "attachments":[{
            "contentType":"application/vnd.microsoft.card.adaptive",
            "content":{
                "$schema":"http://adaptivecards.io/schemas/adaptive-card.json",
                "type":"AdaptiveCard",
                "version":"1.4",
                "body":[
                    {"type":"TextBlock","text":"AWS Report Complete ✅","size":"Large","weight":"Bolder"},
                    {"type":"FactSet","facts":'"${facts}"'}
                ]
            }
        }]
    }'

    # POST to Teams
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$TEAMS_WEBHOOK_URL" 2>/dev/null || echo "000")

    if [[ "$http_code" =~ ^2 ]]; then
        log_success "Teams notification sent successfully"
        return 0
    else
        log_error "Teams notification failed (HTTP $http_code)"
        return 1
    fi
}

send_sns_notification() {
    if [[ -z "${SNS_TOPIC_ARN:-}" ]]; then
        log_error "SNS notification enabled but SNS_TOPIC_ARN is empty"
        return 1
    fi

    local run_date="${YEAR:-$(date +%Y)}-${MONTH:-$(date +%m)}-${DAY:-$(date +%d)}"
    local mode="${RUN_MODE:-all}"

    # Build plain text message
    local message="AWS Cloud Report - Run Summary
==============================
Account:  ${NOTIFIER_ACCOUNT_NAME} (${NOTIFIER_ACCOUNT_ID})
Date:     ${run_date}
Mode:     ${mode}

Results:
  Reports Attempted: ${NOTIFIER_TOTAL_REPORTS}
  Successful:        ${NOTIFIER_SUCCESS_COUNT}
  Failed:            ${NOTIFIER_FAILED_COUNT}

Archive: ${ZIP_FILENAME:-N/A}"

    # Conditional sections
    if [[ -n "${NOTIFIER_SAVINGS:-}" ]]; then
        message="${message}

Optimization Savings: ${NOTIFIER_SAVINGS}/month"
    fi

    if [[ -n "${NOTIFIER_CRITICAL:-}" || -n "${NOTIFIER_HIGH:-}" ]]; then
        message="${message}

Security Findings: ${NOTIFIER_CRITICAL:-0} Critical, ${NOTIFIER_HIGH:-0} High"
    fi

    if [[ -n "${NOTIFIER_HEALTH_SCORE:-}" ]]; then
        message="${message}

Health Score: ${NOTIFIER_HEALTH_SCORE}"
    fi

    local subject="AWS Report: ${NOTIFIER_ACCOUNT_NAME} - ${run_date}"

    # Publish to SNS
    if aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" \
        --message "$message" \
        --output text &>/dev/null; then
        log_success "SNS notification published successfully"
        return 0
    else
        log_error "SNS notification failed"
        return 1
    fi
}

# --- Orchestrator Function ---

send_notifications() {
    # Check if any notifications are enabled
    if [[ "${NOTIFY_SLACK:-0}" != "1" && "${NOTIFY_TEAMS:-0}" != "1" && "${NOTIFY_SNS:-0}" != "1" ]]; then
        return 0
    fi

    # Gather data
    _notifier_get_account_info || true
    _notifier_extract_stats || true
    _notifier_extract_savings || true
    _notifier_extract_security || true
    _notifier_extract_health_score || true

    log_start "📨 Sending notifications..."

    # Send to each enabled channel
    if [[ "${NOTIFY_SLACK:-0}" == "1" ]]; then
        send_slack_notification || true
    fi

    if [[ "${NOTIFY_TEAMS:-0}" == "1" ]]; then
        send_teams_notification || true
    fi

    if [[ "${NOTIFY_SNS:-0}" == "1" ]]; then
        send_sns_notification || true
    fi

    # Always return 0
    return 0
}

#!/bin/bash
# aws_billing_report.sh
# Gathers all consumed services and their costs for a specified time period
# directly from the AWS Billing and Cost Management API.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="../output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_billing_report_$(date +"%Y%m%d-%H%M%S").csv"
START_DATE=""
END_DATE=""

log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for the report (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for the report (YYYY-MM-DD).
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

generate_report() {
    log "✍️ Preparing output file: $OUTPUT_FILE"
    printf '"Service","Total Cost (USD)","Unit"\n' > "$OUTPUT_FILE"

    log "  [Cost Explorer] Fetching cost and usage data by service..."
    COST_DATA=$(aws ce get-cost-and-usage \
        --time-period Start="$START_DATE",End="$END_DATE" \
        --metrics "BlendedCost" \
        --granularity "MONTHLY" \
        --group-by Type=DIMENSION,Key=SERVICE \
        --output json)

    if [[ "$(echo "$COST_DATA" | jq '.ResultsByTime[0].Groups | length')" -eq 0 ]]; then
        log "  [Cost Explorer] No usage data found for the specified period."
    else
        echo "$COST_DATA" | jq -r '.ResultsByTime[0].Groups[] | [.Keys[0], .Metrics.BlendedCost.Amount, .Metrics.BlendedCost.Unit] | @csv' >> "$OUTPUT_FILE"
    fi

    log "✅ DONE. Billing report saved to: $OUTPUT_FILE"
}

main() {
    check_dependencies

    while getopts "b:e:f:h" opt; do
        case "$opt" in
            b)
                START_DATE="$OPTARG"
                ;;
            e)
                END_DATE="$OPTARG"
                ;;
            f)
                OUTPUT_FILE="$OPTARG"
                ;;
            h)
                usage
                ;;
            *)
                usage
                ;;
        esac
    done
    shift $((OPTIND-1))

    if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
        log "❌ Arguments -b and -e are required."
        usage
    fi
    
    generate_report
}

main "$@"
#!/bin/bash
# aws_billing_report.sh
# Gathers all consumed services and their costs for a specified time period
# directly from the AWS Billing and Cost Management API.

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration and Arguments ---
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/aws_billing_report.csv"
START_DATE=""
END_DATE=""

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

# --- Main Script ---
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

log "✍️ Preparing output file: $OUTPUT_FILE"
printf '"Service","Total Cost (USD)","Unit"\n' > "$OUTPUT_FILE"

# The Cost and Usage report is global, so we don't need to loop through regions.
log "  [Cost Explorer] Fetching cost and usage data by service..."
COST_DATA=$(aws ce get-cost-and-usage \
    --time-period Start="$START_DATE",End="$END_DATE" \
    --metrics "BlendedCost" \
    --granularity "MONTHLY" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json)

if [[ "$(echo "$COST_DATA" | jq '.ResultsByTime[0].Groups | length')" -eq 0 ]]; then
    log "  [Cost Explorer] No usage data found for the specified period."
    log "✅ DONE. Report saved to: $OUTPUT_FILE"
    exit 0
fi

echo "$COST_DATA" | jq -r '.ResultsByTime[0].Groups[] | [.Keys[0], .Metrics.BlendedCost.Amount, .Metrics.BlendedCost.Unit] | @csv' >> "$OUTPUT_FILE"

log "✅ DONE. Billing report saved to: $OUTPUT_FILE"

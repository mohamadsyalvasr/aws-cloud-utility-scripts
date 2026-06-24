#!/bin/bash
# bedrock_cost_usage_report.sh
# Gathers a usage report on Amazon Bedrock: token consumption per user/role.
# Uses two approaches:
#   1. Cost Explorer - Bedrock cost breakdown by usage type (always available)
#   2. Model Invocation Logs - Per-user token breakdown (requires logging enabled)
#
# PREREQUISITE: Model Invocation Logging must be enabled in Bedrock console
#               for per-user token data. Without it, only cost data is available.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "us-east-1")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_COST="${OUTPUT_DIR}/bedrock_cost_report.csv"
OUTPUT_FILE_USAGE="${OUTPUT_DIR}/bedrock_usage_per_user_report.csv"
START_DATE=""
END_DATE=""

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-r regions] [-h]

Options:
  -b <start_date>  REQUIRED: Start date (YYYY-MM-DD).
  -e <end_date>    REQUIRED: End date (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions. Default: ${REGIONS[*]}
  -h               Show this help message.

PREREQUISITE: For per-user token data, enable Model Invocation Logging
              in the Amazon Bedrock console (Settings > Model invocation logging).
              Without it, only cost breakdown is available.
EOF
    exit 1
}

while getopts "b:e:r:h" opt; do
    case "$opt" in
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

# --- Dependency Check ---
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE_COST")"

# =========================================================================
# PART 1: Bedrock Cost from Cost Explorer (Global, always available)
# =========================================================================
log "✍️ [Part 1] Generating Bedrock cost breakdown..."
printf '"Usage Type","Cost (USD)","Unit","Period"\n' > "$OUTPUT_FILE_COST"

COST_DATA=$(aws ce get-cost-and-usage \
    --time-period Start="$START_DATE",End="$END_DATE" \
    --metrics "BlendedCost" "UsageQuantity" \
    --granularity "MONTHLY" \
    --filter '{
        "Dimensions": {
            "Key": "SERVICE",
            "Values": ["Amazon Bedrock"]
        }
    }' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json 2>/dev/null || echo '{"ResultsByTime":[]}')

RESULTS_COUNT=$(echo "$COST_DATA" | jq '[.ResultsByTime[].Groups[]] | length')

if [[ "$RESULTS_COUNT" -gt 0 ]]; then
    echo "$COST_DATA" | jq -r --arg period "${START_DATE} to ${END_DATE}" '
        .ResultsByTime[].Groups[] |
        [
            .Keys[0],
            .Metrics.BlendedCost.Amount,
            .Metrics.BlendedCost.Unit,
            $period
        ] | @csv
    ' >> "$OUTPUT_FILE_COST"
    log "  ✅ Bedrock cost data written ($RESULTS_COUNT usage types)."
else
    log "  ⚠️ No Bedrock cost data found for this period."
fi

log "✅ [Part 1] Cost report saved to: $OUTPUT_FILE_COST"

# =========================================================================
# PART 2: Per-User Token Usage from Model Invocation Logs
# =========================================================================
log "✍️ [Part 2] Generating per-user token usage report..."
printf '"User/Role ARN","Model ID","Total Input Tokens","Total Output Tokens","Total Tokens","Invocation Count","Region"\n' > "$OUTPUT_FILE_USAGE"

START_EPOCH=$(date -u -d "$START_DATE 00:00:00" +%s)
END_EPOCH=$(date -u -d "$END_DATE 23:59:59" +%s)

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Check if Model Invocation Logging is enabled
    LOGGING_CONFIG=$(aws bedrock get-model-invocation-logging-configuration \
        --region "$region" --output json 2>/dev/null || echo '{}')

    # Check if logging is configured to CloudWatch
    CW_LOG_GROUP=$(echo "$LOGGING_CONFIG" | jq -r '.loggingConfig.cloudWatchConfig.logGroupName // ""')

    if [[ -z "$CW_LOG_GROUP" ]]; then
        log "  [Bedrock] Model Invocation Logging NOT enabled for CloudWatch in $region. Skipping per-user data."
        log "  [Bedrock] Enable it in Bedrock Console > Settings > Model invocation logging."
        continue
    fi

    log "  [Bedrock] Found log group: $CW_LOG_GROUP. Querying per-user token usage..."

    # Query CloudWatch Logs Insights for per-user token aggregation
    QUERY_ID=$(aws logs start-query \
        --region "$region" \
        --log-group-name "$CW_LOG_GROUP" \
        --start-time "$START_EPOCH" \
        --end-time "$END_EPOCH" \
        --query-string 'stats sum(inputTokenCount) as totalInputTokens, sum(outputTokenCount) as totalOutputTokens, sum(inputTokenCount) + sum(outputTokenCount) as totalTokens, count(*) as invocationCount by identity.arn, modelId | sort totalTokens desc | limit 100' \
        --query "queryId" --output text 2>/dev/null || echo "")

    if [[ -z "$QUERY_ID" ]]; then
        log "  [Bedrock] Failed to start Logs Insights query. Check permissions."
        continue
    fi

    # Wait for query to complete (max 30 seconds)
    log "  [Bedrock] Waiting for query to complete..."
    QUERY_STATUS="Running"
    WAIT_COUNT=0
    while [[ "$QUERY_STATUS" == "Running" || "$QUERY_STATUS" == "Scheduled" ]]; do
        sleep 2
        WAIT_COUNT=$((WAIT_COUNT + 1))
        if [[ $WAIT_COUNT -ge 15 ]]; then
            log "  [Bedrock] Query timeout after 30s. Skipping."
            QUERY_STATUS="Timeout"
            break
        fi
        QUERY_STATUS=$(aws logs get-query-results --region "$region" \
            --query-id "$QUERY_ID" --query "status" --output text 2>/dev/null || echo "Failed")
    done

    if [[ "$QUERY_STATUS" != "Complete" ]]; then
        log "  [Bedrock] Query did not complete (status: $QUERY_STATUS). Skipping."
        continue
    fi

    # Get results
    QUERY_RESULTS=$(aws logs get-query-results --region "$region" \
        --query-id "$QUERY_ID" --output json 2>/dev/null || echo '{"results":[]}')

    RESULT_COUNT=$(echo "$QUERY_RESULTS" | jq '.results | length')

    if [[ "$RESULT_COUNT" -eq 0 ]]; then
        log "  [Bedrock] No invocation data found in logs."
    else
        log "  [Bedrock] Found $RESULT_COUNT user/model combinations."
        echo "$QUERY_RESULTS" | jq -c '.results[]' | while read -r row; do
            # Each row is an array of {field, value} objects
            USER_ARN=$(echo "$row" | jq -r '.[] | select(.field == "identity.arn") | .value // "N/A"')
            MODEL_ID=$(echo "$row" | jq -r '.[] | select(.field == "modelId") | .value // "N/A"')
            INPUT_TOKENS=$(echo "$row" | jq -r '.[] | select(.field == "totalInputTokens") | .value // "0"')
            OUTPUT_TOKENS=$(echo "$row" | jq -r '.[] | select(.field == "totalOutputTokens") | .value // "0"')
            TOTAL_TOKENS=$(echo "$row" | jq -r '.[] | select(.field == "totalTokens") | .value // "0"')
            INVOCATION_COUNT=$(echo "$row" | jq -r '.[] | select(.field == "invocationCount") | .value // "0"')

            printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
                "$USER_ARN" \
                "$MODEL_ID" \
                "$INPUT_TOKENS" \
                "$OUTPUT_TOKENS" \
                "$TOTAL_TOKENS" \
                "$INVOCATION_COUNT" \
                "$region" >> "$OUTPUT_FILE_USAGE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ [Part 2] Per-user usage report saved to: $OUTPUT_FILE_USAGE"
log "✅ DONE. Bedrock usage reports generated."

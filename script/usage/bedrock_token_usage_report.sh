#!/bin/bash
# bedrock_token_usage_report.sh
# Generates a token usage report for Amazon Bedrock and Bedrock Agents
# using CloudWatch Metrics (AWS/Bedrock and AWS/Bedrock/Agents namespaces).
#
# Reports:
#   1. Bedrock Runtime - InputTokenCount & OutputTokenCount per ModelId
#   2. Bedrock Agents  - InputTokenCount & OutputTokenCount per AgentAliasArn + ModelId
#
# Data Source: CloudWatch Metrics (no logging setup required)
#
# Output: CSV files + optional chart generation (PNG + Excel in ZIP)

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "us-east-1")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_BEDROCK="${OUTPUT_DIR}/bedrock_token_usage.csv"
OUTPUT_FILE_AGENTS="${OUTPUT_DIR}/bedrock_agents_token_usage.csv"
OUTPUT_FILE_TIMESERIES="${OUTPUT_DIR}/metrics/bedrock_token_timeseries.json"
START_DATE=""
END_DATE=""
PERIOD=86400  # Default: 1 day granularity (seconds)
GENERATE_CHARTS=false

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-r regions] [-p period] [-g] [-h]

Options:
  -b <start_date>  REQUIRED: Start date (YYYY-MM-DD).
  -e <end_date>    REQUIRED: End date (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions. Default: ${REGIONS[*]}
  -p <period>      Aggregation period in seconds. Default: 86400 (1 day).
                   Common values: 3600 (1 hour), 86400 (1 day).
  -g               Generate charts (PNG) and Excel report, packaged as ZIP.
                   Requires Python3 with matplotlib, pandas, openpyxl.
  -h               Show this help message.

Examples:
  $0 -b 2025-06-01 -e 2025-06-30
  $0 -b 2025-06-01 -e 2025-06-30 -r ap-southeast-1,us-east-1 -g
  $0 -b 2025-06-01 -e 2025-06-30 -p 3600 -g
EOF
    exit 1
}

while getopts "b:e:r:p:gh" opt; do
    case "$opt" in
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        p) PERIOD="$OPTARG" ;;
        g) GENERATE_CHARTS=true ;;
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
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

if [[ "$GENERATE_CHARTS" == "true" ]]; then
    if ! command -v python3 &>/dev/null; then
        log "❌ python3 is required for chart generation. Install Python3."
        exit 1
    fi
    # Check Python dependencies
    python3 -c "import matplotlib, pandas, openpyxl" 2>/dev/null || {
        log "❌ Python dependencies missing. Install with:"
        log "   pip3 install matplotlib pandas openpyxl"
        exit 1
    }
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/metrics"

# =========================================================================
# Helper: Get metric statistics from CloudWatch
# =========================================================================
get_metric_sum() {
    local region="$1"
    local namespace="$2"
    local metric_name="$3"
    local dimensions="$4"

    aws cloudwatch get-metric-statistics \
        --region "$region" \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --start-time "${START_DATE}T00:00:00Z" \
        --end-time "${END_DATE}T23:59:59Z" \
        --period "$PERIOD" \
        --statistics Sum \
        --dimensions $dimensions \
        --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

# =========================================================================
# Helper: Get time-series datapoints for chart generation
# =========================================================================
get_metric_timeseries() {
    local region="$1"
    local namespace="$2"
    local metric_name="$3"
    local dimensions="$4"

    aws cloudwatch get-metric-statistics \
        --region "$region" \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --start-time "${START_DATE}T00:00:00Z" \
        --end-time "${END_DATE}T23:59:59Z" \
        --period "$PERIOD" \
        --statistics Sum \
        --dimensions $dimensions \
        --query "Datapoints[*].{Timestamp:Timestamp,Sum:Sum}" \
        --output json 2>/dev/null || echo '[]'
}

# =========================================================================
# Helper: List all unique dimensions from CloudWatch
# =========================================================================
list_metric_dimensions() {
    local region="$1"
    local namespace="$2"
    local metric_name="$3"

    aws cloudwatch list-metrics \
        --region "$region" \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --output json 2>/dev/null || echo '{"Metrics":[]}'
}

# =========================================================================
# PART 1: Bedrock Runtime Token Usage (AWS/Bedrock namespace)
# =========================================================================
log "═══════════════════════════════════════════════════════════════"
log "  BEDROCK TOKEN USAGE REPORT"
log "  Period: $START_DATE to $END_DATE | Granularity: ${PERIOD}s"
log "═══════════════════════════════════════════════════════════════"
log ""
log "✍️ [Part 1] Bedrock Runtime - Token usage per model..."

printf '"Model ID","Total Input Tokens","Total Output Tokens","Total Tokens","Invocations","Period Start","Period End","Region"\n' > "$OUTPUT_FILE_BEDROCK"

# Initialize time-series JSON
echo "[" > "$OUTPUT_FILE_TIMESERIES"
FIRST_TS_ENTRY=true

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Discover all models that have InputTokenCount metrics
    MODELS_JSON=$(list_metric_dimensions "$region" "AWS/Bedrock" "InputTokenCount")
    MODEL_IDS=$(echo "$MODELS_JSON" | jq -r '.Metrics[].Dimensions[] | select(.Name == "ModelId") | .Value' | sort -u)

    if [[ -z "$MODEL_IDS" ]]; then
        log "  [Bedrock] No token metrics found. No Bedrock invocations in this period."
        continue
    fi

    while IFS= read -r model_id; do
        [[ -z "$model_id" ]] && continue

        # Get InputTokenCount
        INPUT_RESULT=$(get_metric_sum "$region" "AWS/Bedrock" "InputTokenCount" \
            "Name=ModelId,Value=$model_id")
        TOTAL_INPUT=$(echo "$INPUT_RESULT" | jq '[.Datapoints[].Sum] | add // 0 | floor')

        # Get OutputTokenCount
        OUTPUT_RESULT=$(get_metric_sum "$region" "AWS/Bedrock" "OutputTokenCount" \
            "Name=ModelId,Value=$model_id")
        TOTAL_OUTPUT=$(echo "$OUTPUT_RESULT" | jq '[.Datapoints[].Sum] | add // 0 | floor')

        # Get Invocations count
        INVOCATION_RESULT=$(get_metric_sum "$region" "AWS/Bedrock" "Invocations" \
            "Name=ModelId,Value=$model_id")
        TOTAL_INVOCATIONS=$(echo "$INVOCATION_RESULT" | jq '[.Datapoints[].Sum] | add // 0 | floor')

        TOTAL_TOKENS=$((TOTAL_INPUT + TOTAL_OUTPUT))

        if [[ $TOTAL_TOKENS -gt 0 ]]; then
            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$model_id" \
                "$TOTAL_INPUT" \
                "$TOTAL_OUTPUT" \
                "$TOTAL_TOKENS" \
                "$TOTAL_INVOCATIONS" \
                "$START_DATE" \
                "$END_DATE" \
                "$region" >> "$OUTPUT_FILE_BEDROCK"

            log "  [Bedrock] $model_id: Input=$TOTAL_INPUT, Output=$TOTAL_OUTPUT, Total=$TOTAL_TOKENS, Invocations=$TOTAL_INVOCATIONS"

            # Collect time-series for charts
            if [[ "$GENERATE_CHARTS" == "true" ]]; then
                INPUT_TS=$(get_metric_timeseries "$region" "AWS/Bedrock" "InputTokenCount" \
                    "Name=ModelId,Value=$model_id")
                OUTPUT_TS=$(get_metric_timeseries "$region" "AWS/Bedrock" "OutputTokenCount" \
                    "Name=ModelId,Value=$model_id")

                if [[ "$FIRST_TS_ENTRY" == "false" ]]; then echo "," >> "$OUTPUT_FILE_TIMESERIES"; fi
                jq -n --arg model "$model_id" --arg region "$region" --arg source "bedrock" \
                    --argjson input_ts "$INPUT_TS" --argjson output_ts "$OUTPUT_TS" \
                    '{model: $model, region: $region, source: $source, input_tokens: $input_ts, output_tokens: $output_ts}' >> "$OUTPUT_FILE_TIMESERIES"
                FIRST_TS_ENTRY=false
            fi
        fi
    done <<< "$MODEL_IDS"

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ [Part 1] Bedrock runtime token report saved to: $OUTPUT_FILE_BEDROCK"
log ""

# =========================================================================
# PART 2: Bedrock Agents Token Usage (AWS/Bedrock/Agents namespace)
# =========================================================================
log "✍️ [Part 2] Bedrock Agents - Token usage per agent/model..."

printf '"Agent Alias ARN","Model ID","Total Input Tokens","Total Output Tokens","Total Tokens","Model Invocations","Period Start","Period End","Region"\n' > "$OUTPUT_FILE_AGENTS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Discover all agent metrics
    AGENT_METRICS_JSON=$(list_metric_dimensions "$region" "AWS/Bedrock/Agents" "InputTokenCount")
    AGENT_METRICS_COUNT=$(echo "$AGENT_METRICS_JSON" | jq '.Metrics | length')

    if [[ "$AGENT_METRICS_COUNT" -eq 0 ]]; then
        log "  [Agents] No agent token metrics found. No agent invocations in this period."
        continue
    fi

    # Extract unique dimension combinations
    echo "$AGENT_METRICS_JSON" | jq -c '.Metrics[]' | while read -r metric; do
        AGENT_ARN=$(echo "$metric" | jq -r '.Dimensions[] | select(.Name == "AgentAliasArn") | .Value // ""')
        MODEL_ID=$(echo "$metric" | jq -r '.Dimensions[] | select(.Name == "ModelId") | .Value // ""')
        OPERATION=$(echo "$metric" | jq -r '.Dimensions[] | select(.Name == "Operation") | .Value // ""')

        # Build dimensions string
        DIMS=""
        if [[ -n "$AGENT_ARN" && -n "$MODEL_ID" ]]; then
            DIMS="Name=AgentAliasArn,Value=$AGENT_ARN Name=ModelId,Value=$MODEL_ID"
            if [[ -n "$OPERATION" ]]; then
                DIMS="$DIMS Name=Operation,Value=$OPERATION"
            fi
        elif [[ -n "$MODEL_ID" ]]; then
            DIMS="Name=ModelId,Value=$MODEL_ID"
            if [[ -n "$OPERATION" ]]; then
                DIMS="$DIMS Name=Operation,Value=$OPERATION"
            fi
        else
            continue
        fi

        # Get InputTokenCount
        INPUT_RESULT=$(get_metric_sum "$region" "AWS/Bedrock/Agents" "InputTokenCount" "$DIMS")
        TOTAL_INPUT=$(echo "$INPUT_RESULT" | jq '[.Datapoints[].Sum] | add // 0 | floor')

        # Get outputTokenCount (note: lowercase 'o' per AWS docs)
        OUTPUT_RESULT=$(get_metric_sum "$region" "AWS/Bedrock/Agents" "outputTokenCount" "$DIMS")
        TOTAL_OUTPUT=$(echo "$OUTPUT_RESULT" | jq '[.Datapoints[].Sum] | add // 0 | floor')

        # Get ModelInvocationCount
        INVOCATION_RESULT=$(get_metric_sum "$region" "AWS/Bedrock/Agents" "ModelInvocationCount" "$DIMS")
        TOTAL_INVOCATIONS=$(echo "$INVOCATION_RESULT" | jq '[.Datapoints[].Sum] | add // 0 | floor')

        TOTAL_TOKENS=$((TOTAL_INPUT + TOTAL_OUTPUT))

        DISPLAY_AGENT="${AGENT_ARN:-N/A}"

        if [[ $TOTAL_TOKENS -gt 0 ]]; then
            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$DISPLAY_AGENT" \
                "$MODEL_ID" \
                "$TOTAL_INPUT" \
                "$TOTAL_OUTPUT" \
                "$TOTAL_TOKENS" \
                "$TOTAL_INVOCATIONS" \
                "$START_DATE" \
                "$END_DATE" \
                "$region" >> "$OUTPUT_FILE_AGENTS"

            log "  [Agent] ${DISPLAY_AGENT##*/} | $MODEL_ID: Input=$TOTAL_INPUT, Output=$TOTAL_OUTPUT, Invocations=$TOTAL_INVOCATIONS"

            # Collect time-series for charts
            if [[ "$GENERATE_CHARTS" == "true" ]]; then
                INPUT_TS=$(get_metric_timeseries "$region" "AWS/Bedrock/Agents" "InputTokenCount" "$DIMS")
                OUTPUT_TS=$(get_metric_timeseries "$region" "AWS/Bedrock/Agents" "outputTokenCount" "$DIMS")

                if [[ "$FIRST_TS_ENTRY" == "false" ]]; then echo "," >> "$OUTPUT_FILE_TIMESERIES"; fi
                jq -n --arg model "$MODEL_ID" --arg region "$region" --arg source "agent" \
                    --arg agent "$DISPLAY_AGENT" \
                    --argjson input_ts "$INPUT_TS" --argjson output_ts "$OUTPUT_TS" \
                    '{model: $model, region: $region, source: $source, agent: $agent, input_tokens: $input_ts, output_tokens: $output_ts}' >> "$OUTPUT_FILE_TIMESERIES"
                FIRST_TS_ENTRY=false
            fi
        fi
    done

    log "Region \033[1;33m$region\033[0m Complete."
done

# Close time-series JSON
echo "]" >> "$OUTPUT_FILE_TIMESERIES"

log "✅ [Part 2] Bedrock agents token report saved to: $OUTPUT_FILE_AGENTS"
log ""

# =========================================================================
# PART 3: Generate Charts + Excel + ZIP (if -g flag is set)
# =========================================================================
if [[ "$GENERATE_CHARTS" == "true" ]]; then
    log "✍️ [Part 3] Generating charts, Excel, and ZIP package..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PYTHON_SCRIPT="${SCRIPT_DIR}/../lib/python/generate_usage_charts.py"

    if [[ ! -f "$PYTHON_SCRIPT" ]]; then
        log "❌ Python chart script not found: $PYTHON_SCRIPT"
        exit 1
    fi

    python3 "$PYTHON_SCRIPT" \
        "$OUTPUT_DIR" \
        "$OUTPUT_FILE_BEDROCK" \
        "$OUTPUT_FILE_AGENTS" \
        "$OUTPUT_FILE_TIMESERIES" \
        "$START_DATE" \
        "$END_DATE"

    log "✅ [Part 3] Charts and ZIP package generated."
fi

# =========================================================================
# SUMMARY
# =========================================================================
log ""
log "═══════════════════════════════════════════════════════════════"
log "  SUMMARY"
log "═══════════════════════════════════════════════════════════════"
log "  📊 Bedrock Runtime tokens : $OUTPUT_FILE_BEDROCK"
log "  🤖 Bedrock Agents tokens  : $OUTPUT_FILE_AGENTS"
if [[ "$GENERATE_CHARTS" == "true" ]]; then
log "  📦 ZIP package            : ${OUTPUT_DIR}/bedrock_usage_report.zip"
fi
log "  📅 Period                  : $START_DATE to $END_DATE"
log "  🌏 Regions                 : ${REGIONS[*]}"
log "═══════════════════════════════════════════════════════════════"
log "✅ DONE. All Bedrock token usage reports generated."

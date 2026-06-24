#!/bin/bash
# bedrock_token_usage_report.sh
# Generates a comprehensive Bedrock observability report matching CloudWatch
# GenAI Observability dashboard — all metrics per model.
#
# Metrics collected (per ModelId):
#   Token Usage:        InputTokenCount, OutputTokenCount, CacheReadInputTokens, CacheWriteInputTokens
#   Latency:            InvocationLatency, TimeToFirstToken, EstimatedTPMQuotaUsage
#   Volume:             Invocations, InputTokenCount (distribution stats)
#   Reliability:        InvocationThrottles, InvocationClientErrors, InvocationServerErrors
#
# Also collects Bedrock Agents metrics (AWS/Bedrock/Agents namespace).
#
# Data Source: CloudWatch Metrics (no logging setup required)
# Output: JSON metrics file → Python generates Excel (with embedded charts) + ZIP

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "us-east-1")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
METRICS_DIR="${OUTPUT_DIR}/metrics"
METRICS_FILE="${METRICS_DIR}/bedrock_all_metrics.json"
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
  -g               Generate Excel report with embedded charts, packaged as ZIP.
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
        log "⚠️ python3 not found. Attempting to install..."
        if command -v yum &>/dev/null; then
            sudo yum install -y python3 python3-pip >/dev/null 2>&1 || true
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y python3 python3-pip >/dev/null 2>&1 || true
        fi
        if ! command -v python3 &>/dev/null; then
            log "❌ python3 could not be installed. Skipping chart generation."
            GENERATE_CHARTS=false
        fi
    fi

    if [[ "$GENERATE_CHARTS" == "true" ]]; then
        if ! python3 -c "import matplotlib, pandas, openpyxl" 2>/dev/null; then
            log "⚠️ Python dependencies missing. Installing matplotlib, pandas, openpyxl..."
            if pip3 install matplotlib pandas openpyxl >/dev/null 2>&1; then
                log "✅ Python dependencies installed."
            elif sudo pip3 install matplotlib pandas openpyxl >/dev/null 2>&1; then
                log "✅ Python dependencies installed (with sudo)."
            elif pip3 install --user matplotlib pandas openpyxl >/dev/null 2>&1; then
                log "✅ Python dependencies installed (user mode)."
            else
                log "❌ Failed to install Python dependencies. Skipping chart generation."
                log "   Manual fix: pip3 install matplotlib pandas openpyxl"
                GENERATE_CHARTS=false
            fi
        fi
    fi
fi

mkdir -p "$OUTPUT_DIR"
mkdir -p "$METRICS_DIR"

# =========================================================================
# Helper: Get metric time-series with multiple statistics
# =========================================================================
get_metric_data() {
    local region="$1"
    local namespace="$2"
    local metric_name="$3"
    local dimensions="$4"
    local statistics="${5:-Sum}"

    aws cloudwatch get-metric-statistics \
        --region "$region" \
        --namespace "$namespace" \
        --metric-name "$metric_name" \
        --start-time "${START_DATE}T00:00:00Z" \
        --end-time "${END_DATE}T23:59:59Z" \
        --period "$PERIOD" \
        --statistics $statistics \
        --dimensions $dimensions \
        --output json 2>/dev/null || echo '{"Datapoints":[]}'
}

# =========================================================================
# Helper: List all unique ModelId dimensions
# =========================================================================
list_model_ids() {
    local region="$1"
    local namespace="$2"

    aws cloudwatch list-metrics \
        --region "$region" \
        --namespace "$namespace" \
        --metric-name "InputTokenCount" \
        --output json 2>/dev/null || echo '{"Metrics":[]}'
}

# =========================================================================
# COLLECT ALL METRICS
# =========================================================================
log "═══════════════════════════════════════════════════════════════"
log "  BEDROCK OBSERVABILITY REPORT (Full Metrics)"
log "  Period: $START_DATE to $END_DATE | Granularity: ${PERIOD}s"
log "  Regions: ${REGIONS[*]}"
log "═══════════════════════════════════════════════════════════════"
log ""

# All metrics for all models across all regions → single JSON
echo '{"metadata":{},"models":[]}' | jq \
    --arg start "$START_DATE" \
    --arg end "$END_DATE" \
    --arg period "$PERIOD" \
    --arg regions "${REGIONS[*]}" \
    '.metadata = {start_date: $start, end_date: $end, period: ($period|tonumber), regions: $regions}' \
    > "$METRICS_FILE"

# Temporary file for collecting model entries
MODELS_TMP=$(mktemp)
echo "[]" > "$MODELS_TMP"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # =====================================================================
    # BEDROCK RUNTIME (AWS/Bedrock)
    # =====================================================================
    MODELS_JSON=$(list_model_ids "$region" "AWS/Bedrock")
    MODEL_IDS=$(echo "$MODELS_JSON" | jq -r '.Metrics[].Dimensions[] | select(.Name == "ModelId") | .Value' | sort -u)

    if [[ -z "$MODEL_IDS" ]]; then
        log "  [Bedrock] No metrics found in this region."
    else
        while IFS= read -r model_id; do
            [[ -z "$model_id" ]] && continue
            DIMS="Name=ModelId,Value=$model_id"

            log "  [Bedrock] Collecting all metrics for: $model_id"

            # --- Token Usage metrics ---
            INPUT_TOKENS=$(get_metric_data "$region" "AWS/Bedrock" "InputTokenCount" "$DIMS" "Sum SampleCount Average Minimum Maximum")
            OUTPUT_TOKENS=$(get_metric_data "$region" "AWS/Bedrock" "OutputTokenCount" "$DIMS" "Sum SampleCount")
            CACHE_READ=$(get_metric_data "$region" "AWS/Bedrock" "CacheReadInputTokens" "$DIMS" "Sum")
            CACHE_WRITE=$(get_metric_data "$region" "AWS/Bedrock" "CacheWriteInputTokens" "$DIMS" "Sum")

            # --- Latency & Performance metrics ---
            LATENCY=$(get_metric_data "$region" "AWS/Bedrock" "InvocationLatency" "$DIMS" "Average Minimum Maximum SampleCount")
            TTFT=$(get_metric_data "$region" "AWS/Bedrock" "TimeToFirstToken" "$DIMS" "Average Minimum Maximum SampleCount")
            TPM_QUOTA=$(get_metric_data "$region" "AWS/Bedrock" "EstimatedTPMQuotaUsage" "$DIMS" "Sum Average Maximum")

            # --- Volume & Distribution metrics ---
            INVOCATIONS=$(get_metric_data "$region" "AWS/Bedrock" "Invocations" "$DIMS" "Sum SampleCount")

            # --- Reliability & Errors metrics ---
            THROTTLES=$(get_metric_data "$region" "AWS/Bedrock" "InvocationThrottles" "$DIMS" "Sum SampleCount")
            CLIENT_ERRORS=$(get_metric_data "$region" "AWS/Bedrock" "InvocationClientErrors" "$DIMS" "Sum SampleCount")
            SERVER_ERRORS=$(get_metric_data "$region" "AWS/Bedrock" "InvocationServerErrors" "$DIMS" "Sum SampleCount")

            # Build model entry JSON
            MODEL_ENTRY=$(jq -n \
                --arg model_id "$model_id" \
                --arg region "$region" \
                --arg source "bedrock" \
                --argjson input_tokens "$INPUT_TOKENS" \
                --argjson output_tokens "$OUTPUT_TOKENS" \
                --argjson cache_read "$CACHE_READ" \
                --argjson cache_write "$CACHE_WRITE" \
                --argjson latency "$LATENCY" \
                --argjson ttft "$TTFT" \
                --argjson tpm_quota "$TPM_QUOTA" \
                --argjson invocations "$INVOCATIONS" \
                --argjson throttles "$THROTTLES" \
                --argjson client_errors "$CLIENT_ERRORS" \
                --argjson server_errors "$SERVER_ERRORS" \
                '{
                    model_id: $model_id,
                    region: $region,
                    source: $source,
                    metrics: {
                        input_tokens: $input_tokens.Datapoints,
                        output_tokens: $output_tokens.Datapoints,
                        cache_read_tokens: $cache_read.Datapoints,
                        cache_write_tokens: $cache_write.Datapoints,
                        invocation_latency: $latency.Datapoints,
                        time_to_first_token: $ttft.Datapoints,
                        estimated_tpm_quota: $tpm_quota.Datapoints,
                        invocations: $invocations.Datapoints,
                        throttles: $throttles.Datapoints,
                        client_errors: $client_errors.Datapoints,
                        server_errors: $server_errors.Datapoints
                    }
                }')

            # Append to models array
            CURRENT=$(cat "$MODELS_TMP")
            echo "$CURRENT" | jq --argjson entry "$MODEL_ENTRY" '. + [$entry]' > "$MODELS_TMP"

            # Quick summary log
            TOTAL_IN=$(echo "$INPUT_TOKENS" | jq '[.Datapoints[].Sum] | add // 0 | floor')
            TOTAL_OUT=$(echo "$OUTPUT_TOKENS" | jq '[.Datapoints[].Sum] | add // 0 | floor')
            TOTAL_INV=$(echo "$INVOCATIONS" | jq '[.Datapoints[].Sum] | add // 0 | floor')
            log "    → Tokens: In=$TOTAL_IN Out=$TOTAL_OUT | Invocations=$TOTAL_INV"

        done <<< "$MODEL_IDS"
    fi

    # =====================================================================
    # BEDROCK AGENTS (AWS/Bedrock/Agents)
    # =====================================================================
    AGENT_MODELS_JSON=$(list_model_ids "$region" "AWS/Bedrock/Agents")
    AGENT_METRICS_COUNT=$(echo "$AGENT_MODELS_JSON" | jq '.Metrics | length')

    if [[ "$AGENT_METRICS_COUNT" -eq 0 ]]; then
        log "  [Agents] No agent metrics found in this region."
    else
        log "  [Agents] Found $AGENT_METRICS_COUNT metric dimension(s)."

        echo "$AGENT_MODELS_JSON" | jq -c '.Metrics[]' | while read -r metric; do
            AGENT_ARN=$(echo "$metric" | jq -r '.Dimensions[] | select(.Name == "AgentAliasArn") | .Value // ""')
            MODEL_ID=$(echo "$metric" | jq -r '.Dimensions[] | select(.Name == "ModelId") | .Value // ""')
            OPERATION=$(echo "$metric" | jq -r '.Dimensions[] | select(.Name == "Operation") | .Value // ""')

            DIMS=""
            DISPLAY_ID="$MODEL_ID"
            if [[ -n "$AGENT_ARN" && -n "$MODEL_ID" ]]; then
                DIMS="Name=AgentAliasArn,Value=$AGENT_ARN Name=ModelId,Value=$MODEL_ID"
                DISPLAY_ID="${AGENT_ARN##*/}/$MODEL_ID"
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

            log "  [Agents] Collecting metrics for: $DISPLAY_ID"

            INPUT_TOKENS=$(get_metric_data "$region" "AWS/Bedrock/Agents" "InputTokenCount" "$DIMS" "Sum SampleCount")
            OUTPUT_TOKENS=$(get_metric_data "$region" "AWS/Bedrock/Agents" "outputTokenCount" "$DIMS" "Sum SampleCount")
            MODEL_LATENCY=$(get_metric_data "$region" "AWS/Bedrock/Agents" "ModelLatency" "$DIMS" "Average Minimum Maximum SampleCount")
            MODEL_INVOCATIONS=$(get_metric_data "$region" "AWS/Bedrock/Agents" "ModelInvocationCount" "$DIMS" "Sum SampleCount")
            AGENT_THROTTLES=$(get_metric_data "$region" "AWS/Bedrock/Agents" "InvocationThrottles" "$DIMS" "Sum")
            AGENT_CLIENT_ERR=$(get_metric_data "$region" "AWS/Bedrock/Agents" "InvocationClientErrors" "$DIMS" "Sum")
            AGENT_SERVER_ERR=$(get_metric_data "$region" "AWS/Bedrock/Agents" "InvocationServerErrors" "$DIMS" "Sum")
            AGENT_TOTAL_TIME=$(get_metric_data "$region" "AWS/Bedrock/Agents" "TotalTime" "$DIMS" "Average Maximum SampleCount")

            MODEL_ENTRY=$(jq -n \
                --arg model_id "$MODEL_ID" \
                --arg agent_arn "${AGENT_ARN:-N/A}" \
                --arg region "$region" \
                --arg source "agent" \
                --argjson input_tokens "$INPUT_TOKENS" \
                --argjson output_tokens "$OUTPUT_TOKENS" \
                --argjson model_latency "$MODEL_LATENCY" \
                --argjson model_invocations "$MODEL_INVOCATIONS" \
                --argjson throttles "$AGENT_THROTTLES" \
                --argjson client_errors "$AGENT_CLIENT_ERR" \
                --argjson server_errors "$AGENT_SERVER_ERR" \
                --argjson total_time "$AGENT_TOTAL_TIME" \
                '{
                    model_id: $model_id,
                    agent_arn: $agent_arn,
                    region: $region,
                    source: $source,
                    metrics: {
                        input_tokens: $input_tokens.Datapoints,
                        output_tokens: $output_tokens.Datapoints,
                        model_latency: $model_latency.Datapoints,
                        model_invocations: $model_invocations.Datapoints,
                        throttles: $throttles.Datapoints,
                        client_errors: $client_errors.Datapoints,
                        server_errors: $server_errors.Datapoints,
                        total_time: $total_time.Datapoints
                    }
                }')

            # Append (use temp file in subshell-safe way)
            CURRENT=$(cat "$MODELS_TMP")
            echo "$CURRENT" | jq --argjson entry "$MODEL_ENTRY" '. + [$entry]' > "$MODELS_TMP"

        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
    log ""
done

# Assemble final JSON
MODELS_ARRAY=$(cat "$MODELS_TMP")
jq --argjson models "$MODELS_ARRAY" '.models = $models' "$METRICS_FILE" > "${METRICS_FILE}.tmp"
mv "${METRICS_FILE}.tmp" "$METRICS_FILE"
rm -f "$MODELS_TMP"

TOTAL_MODELS=$(echo "$MODELS_ARRAY" | jq 'length')
log "✅ All metrics collected: $TOTAL_MODELS model(s) across ${#REGIONS[@]} region(s)"
log "   Metrics JSON: $METRICS_FILE"
log ""

# =========================================================================
# GENERATE EXCEL + CHARTS + ZIP
# =========================================================================
if [[ "$GENERATE_CHARTS" == "true" ]]; then
    log "✍️ Generating Excel report with embedded charts..."

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PYTHON_SCRIPT="${SCRIPT_DIR}/../../lib/python/generate_usage_charts.py"

    if [[ ! -f "$PYTHON_SCRIPT" ]]; then
        log "❌ Python chart script not found: $PYTHON_SCRIPT"
        exit 1
    fi

    python3 "$PYTHON_SCRIPT" "$METRICS_FILE" "$OUTPUT_DIR" "$START_DATE" "$END_DATE"

    log "✅ Excel report with charts generated."
fi

# =========================================================================
# SUMMARY
# =========================================================================
log ""
log "═══════════════════════════════════════════════════════════════"
log "  SUMMARY"
log "═══════════════════════════════════════════════════════════════"
log "  📊 Metrics JSON           : $METRICS_FILE"
if [[ "$GENERATE_CHARTS" == "true" ]]; then
log "  📈 Excel Report           : ${OUTPUT_DIR}/Bedrock_Observability_Report.xlsx"
log "  📦 ZIP package            : ${OUTPUT_DIR}/bedrock_usage_report.zip"
fi
log "  📅 Period                  : $START_DATE to $END_DATE"
log "  🌏 Regions                 : ${REGIONS[*]}"
log "  🔢 Models collected        : $TOTAL_MODELS"
log "═══════════════════════════════════════════════════════════════"
log "✅ DONE. Bedrock observability report generated."

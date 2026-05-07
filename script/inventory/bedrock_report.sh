#!/bin/bash
# bedrock_report.sh
# Gathers a report on Amazon Bedrock resources (Provisioned Throughput, Custom Models, Agents).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/bedrock_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
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

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Resource Type","Name/Model ID","Status","Model Provider","Commitment","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- Provisioned Model Throughputs ---
    PROVISIONED=$(aws bedrock list-provisioned-model-throughputs --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$PROVISIONED" && "$(echo "$PROVISIONED" | jq '.provisionedModelSummaries | length')" -gt 0 ]]; then
        echo "$PROVISIONED" | jq -r --arg r "$region" '.provisionedModelSummaries[] | [
            "Provisioned Throughput",
            .provisionedModelName,
            .status,
            (.foundationModelArn // "N/A" | split("/") | last),
            (.commitmentDuration // "N/A"),
            (.creationTime // "N/A"),
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Provisioned Throughput] No provisioned throughputs found."
    fi

    # --- Custom Models ---
    CUSTOM_MODELS=$(aws bedrock list-custom-models --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$CUSTOM_MODELS" && "$(echo "$CUSTOM_MODELS" | jq '.modelSummaries | length')" -gt 0 ]]; then
        echo "$CUSTOM_MODELS" | jq -r --arg r "$region" '.modelSummaries[] | [
            "Custom Model",
            .modelName,
            "ACTIVE",
            (.baseModelName // "N/A"),
            "N/A",
            (.creationTime // "N/A"),
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Custom Models] No custom models found."
    fi

    # --- Bedrock Agents ---
    AGENTS=$(aws bedrock-agent list-agents --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$AGENTS" && "$(echo "$AGENTS" | jq '.agentSummaries | length')" -gt 0 ]]; then
        echo "$AGENTS" | jq -r --arg r "$region" '.agentSummaries[] | [
            "Agent",
            .agentName,
            .agentStatus,
            "N/A",
            "N/A",
            (.updatedAt // .createdAt // "N/A"),
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Agents] No Bedrock agents found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

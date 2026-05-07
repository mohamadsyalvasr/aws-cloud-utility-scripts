#!/bin/bash
# sagemaker_report.sh
# Gathers a report on Amazon SageMaker resources (Endpoints, Notebook Instances, Models).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sagemaker_report.csv"

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

printf '"Resource Type","Name","Status","Instance Type","Instance Count","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- SageMaker Endpoints ---
    ENDPOINTS=$(aws sagemaker list-endpoints --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$ENDPOINTS" && "$(echo "$ENDPOINTS" | jq '.Endpoints | length')" -gt 0 ]]; then
        ENDPOINT_NAMES=$(echo "$ENDPOINTS" | jq -r '.Endpoints[].EndpointName')
        while IFS= read -r ep_name; do
            EP_DETAIL=$(aws sagemaker describe-endpoint --endpoint-name "$ep_name" --region "$region" --output json 2>/dev/null || true)
            if [[ -n "$EP_DETAIL" ]]; then
                echo "$EP_DETAIL" | jq -r --arg r "$region" '[
                    "Endpoint",
                    .EndpointName,
                    .EndpointStatus,
                    (.ProductionVariants[0].CurrentInstanceCount // "N/A" | tostring),
                    (.ProductionVariants[0].InstanceType // "N/A"),
                    (.CreationTime // "N/A"),
                    $r
                ] | @csv' | awk -F',' '{print $1","$2","$3","$5","$4","$6","$7}' >> "$OUTPUT_FILE"
            fi
        done <<< "$ENDPOINT_NAMES"
    else
        log "  [Endpoints] No endpoints found."
    fi

    # --- SageMaker Notebook Instances ---
    NOTEBOOKS=$(aws sagemaker list-notebook-instances --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$NOTEBOOKS" && "$(echo "$NOTEBOOKS" | jq '.NotebookInstances | length')" -gt 0 ]]; then
        echo "$NOTEBOOKS" | jq -r --arg r "$region" '.NotebookInstances[] | [
            "Notebook Instance",
            .NotebookInstanceName,
            .NotebookInstanceStatus,
            .InstanceType,
            "1",
            .CreationTime,
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Notebook Instances] No notebook instances found."
    fi

    # --- SageMaker Models ---
    MODELS=$(aws sagemaker list-models --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$MODELS" && "$(echo "$MODELS" | jq '.Models | length')" -gt 0 ]]; then
        echo "$MODELS" | jq -r --arg r "$region" '.Models[] | [
            "Model",
            .ModelName,
            "N/A",
            "N/A",
            "N/A",
            .CreationTime,
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Models] No models found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# codepipeline_report.sh
# Gathers an inventory report on all CodePipeline pipelines.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/codepipeline_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]
Options:
  -r <regions>     Comma-separated list of AWS regions. Default: ${REGIONS[*]}
  -h               Show this help message.
EOF
    exit 1
}

while getopts "r:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

# --- Main Script ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Pipeline Name","Pipeline ARN","Stage Count","Created Date","Updated Date","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    PIPELINES_DATA=$(aws codepipeline list-pipelines --region "$region" --output json --no-paginate 2>/dev/null || echo '{"pipelines":[]}')
    PIPELINE_COUNT=$(echo "$PIPELINES_DATA" | jq '.pipelines // [] | length')

    if [[ "$PIPELINE_COUNT" -eq 0 ]]; then
        log "  [CodePipeline] No pipelines found."
    else
        log "  [CodePipeline] Found $PIPELINE_COUNT pipelines. Fetching details..."

        echo "$PIPELINES_DATA" | jq -c '.pipelines // [] | .[]' | while read -r pipeline; do
            PIPELINE_NAME=$(echo "$pipeline" | jq -r '.name // "N/A"')
            CREATED_DATE=$(echo "$pipeline" | jq -r '.created // "N/A"')
            UPDATED_DATE=$(echo "$pipeline" | jq -r '.updated // "N/A"')

            # Get pipeline details for stage count and ARN
            PIPELINE_DETAIL=$(aws codepipeline get-pipeline --region "$region" \
                --name "$PIPELINE_NAME" --output json 2>/dev/null || echo '{}')

            if [[ -z "$PIPELINE_DETAIL" || "$PIPELINE_DETAIL" == "{}" ]]; then
                STAGE_COUNT="N/A"
                PIPELINE_ARN="N/A"
            else
                STAGE_COUNT=$(echo "$PIPELINE_DETAIL" | jq '.pipeline.stages // [] | length')
                PIPELINE_ARN=$(echo "$PIPELINE_DETAIL" | jq -r '.metadata.pipelineArn // "N/A"')
            fi

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$PIPELINE_NAME" \
                "$PIPELINE_ARN" \
                "$STAGE_COUNT" \
                "$CREATED_DATE" \
                "$UPDATED_DATE" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

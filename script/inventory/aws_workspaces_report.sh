#!/bin/bash
# aws_workspaces_report.sh
# Gathers a detailed report on AWS WorkSpaces, including last active time.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_workspaces_report.csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1; then
        log "❌ AWS CLI not found. Please install it first."
        exit 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log "❌ jq not found. Please install it first."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script ---
check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"WorkspaceID","Username","Compute","Root Volume","User Volume","OS","Running mode","Protocol","Status","Last Active","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    WORKSPACES_DATA=$(aws workspaces describe-workspaces --region "$region" --output json)
    
    if [[ "$(echo "$WORKSPACES_DATA" | jq '.Workspaces | length')" -eq 0 ]]; then
        log "  [WorkSpaces] No WorkSpaces found."
    else
        echo "$WORKSPACES_DATA" | jq -c '.Workspaces[]' | while read -r workspace; do
            WORKSPACE_ID=$(echo "$workspace" | jq -r '.WorkspaceId // "N/A"')
            USERNAME=$(echo "$workspace" | jq -r '.UserName // "N/A"')
            COMPUTE=$(echo "$workspace" | jq -r '.WorkspaceProperties.ComputeTypeName // "N/A"')
            ROOT_VOLUME=$(echo "$workspace" | jq -r '.WorkspaceProperties.RootVolumeSizeGib // "N/A"')
            USER_VOLUME=$(echo "$workspace" | jq -r '.WorkspaceProperties.UserVolumeSizeGib // "N/A"')
            OS=$(echo "$workspace" | jq -r '.OperatingSystem.Type // "N/A"')
            RUNNING_MODE=$(echo "$workspace" | jq -r '.WorkspaceProperties.RunningMode // "N/A"')
            PROTOCOL=$(echo "$workspace" | jq -r '[.WorkspaceProperties.Protocols[]] | join(", ") // "N/A"')
            STATUS=$(echo "$workspace" | jq -r '.State // "N/A"')

            # Get the last active time using a separate API call
            LAST_ACTIVE_RAW=$(aws workspaces describe-workspaces-connection-status \
                --region "$region" \
                --workspace-ids "$WORKSPACE_ID" \
                --query 'WorkspacesConnectionStatus[0].LastKnownUserConnectionTimestamp' \
                --output text 2>/dev/null || echo "None")

            # Handle the timestamp - AWS CLI may return:
            # - "None" if no connection ever made
            # - An epoch float like "1705312200.0"
            # - An ISO 8601 string like "2024-01-15T10:30:00+00:00"
            LAST_ACTIVE_TIME="N/A"
            if [[ -n "$LAST_ACTIVE_RAW" && "$LAST_ACTIVE_RAW" != "None" && "$LAST_ACTIVE_RAW" != "null" ]]; then
                # Check if it's a numeric epoch timestamp (with possible decimal)
                if [[ "$LAST_ACTIVE_RAW" =~ ^[0-9]+\.?[0-9]*$ ]]; then
                    # It's an epoch timestamp - convert integer part
                    EPOCH_INT=$(echo "$LAST_ACTIVE_RAW" | cut -d'.' -f1)
                    LAST_ACTIVE_TIME=$(date -u -d "@${EPOCH_INT}" +"%Y-%m-%d %H:%M:%S UTC" 2>/dev/null || echo "$LAST_ACTIVE_RAW")
                else
                    # It's likely ISO 8601 - use as-is (already human readable)
                    LAST_ACTIVE_TIME="$LAST_ACTIVE_RAW"
                fi
            fi

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$WORKSPACE_ID" \
                "$USERNAME" \
                "$COMPUTE" \
                "$ROOT_VOLUME" \
                "$USER_VOLUME" \
                "$OS" \
                "$RUNNING_MODE" \
                "$PROTOCOL" \
                "$STATUS" \
                "$LAST_ACTIVE_TIME" \
                "$region" >> "$OUTPUT_FILE"
        done
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"
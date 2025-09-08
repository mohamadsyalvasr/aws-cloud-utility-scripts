#!/bin/bash
# aws_workspaces_report.sh
# Gathers a detailed report on AWS WorkSpaces, including last active time.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/aws_workspaces_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: aws_workspaces_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script Logic ---
main() {
    check_dependencies
    
    while getopts "r:f:h" opt; do
        case "$opt" in
            r)
                IFS=',' read -r -a REGIONS <<< "$OPTARG"
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

    log "✍️ Preparing output file: $OUTPUT_FILE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"

    # Create CSV header with the requested columns
    printf '"WorkspaceID","Username","Compute","Root Volume","User Volume","OS","Running mode","Protocol","Status","Last Active","Region"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local workspaces_data=$(aws workspaces describe-workspaces --region "$region" --output json)
        
        if [[ "$(echo "$workspaces_data" | jq '.Workspaces | length')" -eq 0 ]]; then
            log "  [WorkSpaces] No WorkSpaces found."
        else
            echo "$workspaces_data" | jq -c '.Workspaces[]' | while read -r workspace; do
                local workspace_id=$(echo "$workspace" | jq -r '.WorkspaceId // "N/A"')
                local username=$(echo "$workspace" | jq -r '.UserName // "N/A"')
                local compute=$(echo "$workspace" | jq -r '.WorkspaceProperties.ComputeTypeName // "N/A"')
                local root_volume=$(echo "$workspace" | jq -r '.WorkspaceProperties.RootVolumeSizeGib // "N/A"')
                local user_volume=$(echo "$workspace" | jq -r '.WorkspaceProperties.UserVolumeSizeGib // "N/A"')
                local os=$(echo "$workspace" | jq -r '.OperatingSystem.Type // "N/A"')
                local running_mode=$(echo "$workspace" | jq -r '.WorkspaceProperties.RunningMode // "N/A"')
                local protocol=$(echo "$workspace" | jq -r '[.WorkspaceProperties.Protocols[]] | join(", ") // "N/A"')
                local status=$(echo "$workspace" | jq -r '.State // "N/A"')

                local last_active_unix=$(aws workspaces describe-workspaces-connection-status \
                    --region "$region" \
                    --workspace-ids "$workspace_id" \
                    --query 'WorkspacesConnectionStatus[0].LastKnownUserConnectionTimestamp' \
                    --output text)

                local last_active_time="N/A"
                if [ -n "$last_active_unix" ] && [ "$last_active_unix" != "None" ]; then
                    last_active_time=$(date -d @"$last_active_unix" -u +"%Y-%m-%d %H:%M:%S UTC")
                fi

                printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$workspace_id" \
                    "$username" \
                    "$compute" \
                    "$root_volume" \
                    "$user_volume" \
                    "$os" \
                    "$running_mode" \
                    "$protocol" \
                    "$status" \
                    "$last_active_time" \
                    "$region" >> "$OUTPUT_FILE"
            done
        fi

        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
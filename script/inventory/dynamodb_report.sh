#!/bin/bash
# dynamodb_report.sh
# Gathers a report on DynamoDB tables.

set -euo pipefail

# Shared helpers: logging, check_dependencies, init_output_dir.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/common.sh"

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
init_output_dir
OUTPUT_FILE="${OUTPUT_DIR}/dynamodb_report.csv"

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions]
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

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"TableName","TableStatus","ItemCount","TableSizeBytes","CreationDateTime","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"
    
    # List tables (--no-paginate to get all tables)
    TABLE_NAMES=$(aws dynamodb list-tables --region "$region" --query "TableNames[]" --output text --no-paginate)
    
    if [ -n "$TABLE_NAMES" ] && [ "$TABLE_NAMES" != "None" ]; then
        for table in $TABLE_NAMES; do
            # Describe each table to get details
             # Note: This might be slow if there are many tables.
            DETAILS=$(aws dynamodb describe-table --region "$region" --table-name "$table" --output json)
            
            echo "$DETAILS" | jq -r --arg r "$region" '.Table | [.TableName, .TableStatus, .ItemCount, .TableSizeBytes, .CreationDateTime, $r] | @csv' >> "$OUTPUT_FILE"
        done
    else
        log "  [DynamoDB] No tables found."
    fi
     log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

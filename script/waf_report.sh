#!/bin/bash
# waf_report.sh
# Gathers a report on all AWS WAF Web ACLs, including allowed and blocked requests.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/waf_report_$(date +"%Y%m%d-%H%M%S").csv"
START_DATE=""
END_DATE=""
PERIOD=86400 # Default to 1 day in seconds

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-r regions] [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for the report (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for the report (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: waf_report_<timestamp>.csv
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
    
    while getopts "b:e:r:f:h" opt; do
        case "$opt" in
            b) START_DATE="$OPTARG" ;;
            e) END_DATE="$OPTARG" ;;
            r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
            f) OUTPUT_FILE="$OPTARG" ;;
            h) usage ;;
            *) usage ;;
        esac
    done
    shift $((OPTIND-1))

    if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
        log "❌ Arguments -b and -e are required."
        usage
    fi

    local start_time=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ")
    local end_time=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ")

    log "✍️ Preparing output file: $OUTPUT_FILE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"
    printf '"Name","ID","Allowed Requests","Blocked Requests","Creation Time","Region"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local waf_data=$(aws wafv2 list-web-acls --scope REGIONAL --region "$region" --output json)
        
        if [[ "$(echo "$waf_data" | jq '.WebACLs | length')" -gt 0 ]]; then
            echo "$waf_data" | jq -c '.WebACLs[]' | while read -r web_acl; do
                local name=$(echo "$web_acl" | jq -r '.Name')
                local id=$(echo "$web_acl" | jq -r '.Id')
                
                local created_date="N/A"
                if local created_time_raw=$(aws wafv2 get-web-acl --scope REGIONAL --region "$region" --name "$name" --id "$id" --query 'WebACL.CreationTime' --output text 2>/dev/null); then
                    created_date=$created_time_raw
                fi

                local allowed_requests=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/WAFV2 \
                    --metric-name AllowedRequests \
                    --dimensions Name=WebACL,Value="$name" Name=Rule,Value="All" \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period "$PERIOD" \
                    --statistics Sum \
                    --query "Datapoints[0].Sum" \
                    --output text || echo "0")

                local blocked_requests=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/WAFV2 \
                    --metric-name BlockedRequests \
                    --dimensions Name=WebACL,Value="$name" Name=Rule,Value="All" \
                    --start-time "$start_time" \
                    --end-time "$end_time" \
                    --period "$PERIOD" \
                    --statistics Sum \
                    --query "Datapoints[0].Sum" \
                    --output text || echo "0")

                printf '"%s","%s","%s","%s","%s","%s"\n' \
                    "$name" \
                    "$id" \
                    "${allowed_requests}" \
                    "${blocked_requests}" \
                    "$created_date" \
                    "$region" >> "$OUTPUT_FILE"
            done
        else
            log "  [WAF] No Web ACLs found."
        fi

        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
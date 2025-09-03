#!/bin/bash
# waf_report.sh
# Gathers a report on all AWS WAF Web ACLs, including allowed and blocked requests.

set -euo pipefail

# --- Configuration ---
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

# Process command-line arguments for date range
while getopts "b:e:r:h" opt; do
    case "$opt" in
        b)
            START_DATE="$OPTARG"
            ;;
        e)
            END_DATE="$OPTARG"
            ;;
        r)
            IFS=',' read -r -a REGIONS <<< "$OPTARG"
            ;;
        h)
            echo "Usage: $0 -b <start_date> -e <end_date> [-r <regions>]"
            exit 0
            ;;
        *)
            echo "Usage: $0 -b <start_date> -e <end_date> [-r <regions>]"
            exit 1
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    echo "Usage: $0 -b <start_date> -e <end_date> [-r <regions>]"
    exit 1
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

check_dependencies
log "✍️ Preparing output file: $OUTPUT_FILE"

# Create CSV header with the requested columns
printf '"Name","ID","Allowed Requests","Blocked Requests","Creation Time","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get a list of all Web ACLs in the region
    WAF_DATA=$(aws wafv2 list-web-acls --scope REGIONAL --region "$region" --output json)
    
    if [[ "$(echo "$WAF_DATA" | jq '.WebACLs | length')" -gt 0 ]]; then
        echo "$WAF_DATA" | jq -c '.WebACLs[]' | while read -r web_acl; do
            NAME=$(echo "$web_acl" | jq -r '.Name')
            ID=$(echo "$web_acl" | jq -r '.Id')
            ARN=$(echo "$web_acl" | jq -r '.ARN')
            CREATED_DATE="N/A" # Creation time is not in list-web-acls, need to describe for each

            # Fetch allowed requests from CloudWatch
            ALLOWED_REQUESTS=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/WAFV2 \
                --metric-name AllowedRequests \
                --dimensions Name=WebACL,Value="$NAME" Name=Rule,Value="All" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text)

            # Fetch blocked requests from CloudWatch
            BLOCKED_REQUESTS=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/WAFV2 \
                --metric-name BlockedRequests \
                --dimensions Name=WebACL,Value="$NAME" Name=Rule,Value="All" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[0].Sum" \
                --output text)

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$ID" \
                "${ALLOWED_REQUESTS:-0}" \
                "${BLOCKED_REQUESTS:-0}" \
                "$CREATED_DATE" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [WAF] No Web ACLs found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

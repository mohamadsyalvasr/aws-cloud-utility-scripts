#!/bin/bash
# waf_report.sh
# Gathers a report on all AWS WAF Web ACLs, including allowed and blocked requests.

set -euo pipefail

# --- Configuration ---
# Default values, can be overridden by command-line arguments
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

# --- Process command-line arguments ---
while getopts "b:e:r:f:h" opt; do
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

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ")
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

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

mkdir -p "$(dirname "$OUTPUT_FILE")"

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

            # Get creation time by describing the Web ACL
            CREATED_DATE="N/A"
            if CREATED_TIME_RAW=$(aws wafv2 get-web-acl --scope REGIONAL --region "$region" --name "$NAME" --id "$ID" --query 'WebACL.CreationTime' --output text 2>/dev/null); then
                CREATED_DATE=$CREATED_TIME_RAW
            fi

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
                --output text || echo "0") # Default to 0 if no data

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
                --output text || echo "0") # Default to 0 if no data

            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$NAME" \
                "$ID" \
                "${ALLOWED_REQUESTS}" \
                "${BLOCKED_REQUESTS}" \
                "$CREATED_DATE" \
                "$region" >> "$OUTPUT_FILE"
        done
    else
        log "  [WAF] No Web ACLs found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# tagging_compliance_report.sh
# Checks AWS resources for mandatory tags using the Resource Groups Tagging API.
# Produces a CSV compliance report showing missing tags and compliance percentages.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/tagging_compliance_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[*]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: tagging_compliance_report.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Process command-line arguments ---
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

# --- Dependency Check ---
log "🔎 Checking dependencies (aws, jq, bc)..."
for cmd in aws jq bc; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done
log "✅ Dependencies met."

# --- Parse MANDATORY_TAGS ---
RAW_TAGS="${MANDATORY_TAGS:-Environment,Owner,CostCenter,Project}"
IFS=',' read -r -a TAG_ARRAY <<< "$RAW_TAGS"
MANDATORY_TAG_LIST=()
for tag in "${TAG_ARRAY[@]}"; do
    trimmed=$(echo "$tag" | xargs)
    if [[ -n "$trimmed" ]]; then
        MANDATORY_TAG_LIST+=("$trimmed")
    fi
done
TOTAL_MANDATORY=${#MANDATORY_TAG_LIST[@]}

log "📋 Mandatory tags ($TOTAL_MANDATORY): ${MANDATORY_TAG_LIST[*]}"

# --- Resource Type Filters ---
RESOURCE_TYPE_FILTERS=(
    "ec2:instance"
    "rds:db"
    "s3"
    "lambda:function"
    "ec2:volume"
    "elasticloadbalancing:loadbalancer"
    "elasticfilesystem:file-system"
    "eks:cluster"
)

# --- Setup ---
mkdir -p "${OUTPUT_DIR}"
log "✍️ Preparing output file: $OUTPUT_FILE"

# --- Write CSV Header ---
printf '"Resource Type","Resource ID","Resource Name","Missing Tags","Compliance %%","Region"\n' > "$OUTPUT_FILE"

# --- Temp directory for per-type stats (avoids subshell variable issues) ---
STATS_DIR=$(mktemp -d)
trap 'rm -rf "$STATS_DIR"' EXIT

# Initialize stats files for each resource type
for filter in "${RESOURCE_TYPE_FILTERS[@]}"; do
    echo "0" > "${STATS_DIR}/${filter//[:\/]/_}_count"
    echo "0" > "${STATS_DIR}/${filter//[:\/]/_}_noncompliant"
    echo "0" > "${STATS_DIR}/${filter//[:\/]/_}_compliance_sum"
done

# --- Helper: derive friendly resource type from ARN filter ---
get_resource_type_label() {
    local filter="$1"
    case "$filter" in
        ec2:instance) echo "EC2" ;;
        rds:db) echo "RDS" ;;
        s3) echo "S3" ;;
        lambda:function) echo "Lambda" ;;
        ec2:volume) echo "EBS" ;;
        elasticloadbalancing:loadbalancer) echo "ELB" ;;
        elasticfilesystem:file-system) echo "EFS" ;;
        eks:cluster) echo "EKS" ;;
        *) echo "$filter" ;;
    esac
}

# --- Helper: extract resource ID from ARN ---
extract_resource_id() {
    local arn="$1"
    local filter="$2"
    case "$filter" in
        s3)
            # arn:aws:s3:::bucket-name
            echo "$arn" | awk -F':::' '{print $2}'
            ;;
        ec2:instance|ec2:volume)
            # arn:aws:ec2:region:account:instance/i-xxx or volume/vol-xxx
            echo "$arn" | awk -F'/' '{print $NF}'
            ;;
        rds:db)
            # arn:aws:rds:region:account:db:mydb
            echo "$arn" | awk -F':db:' '{print $2}'
            ;;
        lambda:function)
            # arn:aws:lambda:region:account:function:name
            echo "$arn" | awk -F':function:' '{print $2}'
            ;;
        elasticloadbalancing:loadbalancer)
            # arn:aws:elasticloadbalancing:region:account:loadbalancer/type/name/id
            echo "$arn" | awk -F'loadbalancer/' '{print $2}'
            ;;
        elasticfilesystem:file-system)
            # arn:aws:elasticfilesystem:region:account:file-system/fs-xxx
            echo "$arn" | awk -F'/' '{print $NF}'
            ;;
        eks:cluster)
            # arn:aws:eks:region:account:cluster/name
            echo "$arn" | awk -F'/' '{print $NF}'
            ;;
        *)
            echo "$arn" | awk -F'/' '{print $NF}'
            ;;
    esac
}

# --- Process resources for a given region and resource type filter ---
process_resources() {
    local region="$1"
    local filter="$2"
    local type_label
    type_label=$(get_resource_type_label "$filter")
    local stats_key="${filter//[:\/]/_}"

    local pagination_token=""
    local has_more=true

    while [[ "$has_more" == "true" ]]; do
        local cmd_args=(aws resourcegroupstaggingapi get-resources
            --resource-type-filters "$filter"
            --output json)

        # S3 is global, but the tagging API still works per-region; we query it only once
        if [[ "$filter" != "s3" ]]; then
            cmd_args+=(--region "$region")
        fi

        if [[ -n "$pagination_token" ]]; then
            cmd_args+=(--starting-token "$pagination_token")
        fi

        local result
        result=$("${cmd_args[@]}" 2>/dev/null) || {
            log "  ⚠️ API call failed for $type_label in $region. Skipping."
            return 0
        }

        # Check for pagination
        pagination_token=$(echo "$result" | jq -r '.PaginationToken // empty')
        if [[ -z "$pagination_token" ]]; then
            has_more=false
        fi

        local resource_count
        resource_count=$(echo "$result" | jq '.ResourceTagMappingList | length')

        if [[ "$resource_count" -eq 0 ]]; then
            break
        fi

        # Process each resource
        for i in $(seq 0 $((resource_count - 1))); do
            local resource
            resource=$(echo "$result" | jq -c ".ResourceTagMappingList[$i]")

            local arn
            arn=$(echo "$resource" | jq -r '.ResourceARN')

            local resource_id
            resource_id=$(extract_resource_id "$arn" "$filter")

            # Get Name tag
            local resource_name
            resource_name=$(echo "$resource" | jq -r '.Tags[] | select(.Key == "Name") | .Value // empty' 2>/dev/null || echo "")
            if [[ -z "$resource_name" ]]; then
                resource_name="N/A"
            fi

            # Get existing tag keys
            local existing_keys
            existing_keys=$(echo "$resource" | jq -r '.Tags[].Key' 2>/dev/null || echo "")

            # Compare against mandatory tags
            local missing_tags=()
            local present_count=0
            for mtag in "${MANDATORY_TAG_LIST[@]}"; do
                if echo "$existing_keys" | grep -qx "$mtag"; then
                    present_count=$((present_count + 1))
                else
                    missing_tags+=("$mtag")
                fi
            done

            # Calculate compliance percentage
            local compliance_pct
            if [[ "$TOTAL_MANDATORY" -gt 0 ]]; then
                compliance_pct=$(echo "scale=1; ($present_count / $TOTAL_MANDATORY) * 100" | bc)
            else
                compliance_pct="100.0"
            fi

            # Format missing tags as semicolon-separated
            local missing_str=""
            if [[ ${#missing_tags[@]} -gt 0 ]]; then
                missing_str=$(IFS=';'; echo "${missing_tags[*]}")
            fi

            # Write CSV row
            printf '"%s","%s","%s","%s","%s","%s"\n' \
                "$type_label" \
                "$resource_id" \
                "$resource_name" \
                "$missing_str" \
                "$compliance_pct" \
                "$region" >> "$OUTPUT_FILE"

            # Update stats
            local current_count
            current_count=$(cat "${STATS_DIR}/${stats_key}_count")
            echo $((current_count + 1)) > "${STATS_DIR}/${stats_key}_count"

            local current_sum
            current_sum=$(cat "${STATS_DIR}/${stats_key}_compliance_sum")
            echo "$current_sum + $compliance_pct" | bc > "${STATS_DIR}/${stats_key}_compliance_sum"

            if [[ ${#missing_tags[@]} -gt 0 ]]; then
                local current_nc
                current_nc=$(cat "${STATS_DIR}/${stats_key}_noncompliant")
                echo $((current_nc + 1)) > "${STATS_DIR}/${stats_key}_noncompliant"
            fi
        done
    done
}

# --- Main Loop ---
TOTAL_REGIONS=${#REGIONS[@]}
REGION_INDEX=0
S3_QUERIED=false

for region in "${REGIONS[@]}"; do
    REGION_INDEX=$((REGION_INDEX + 1))
    log "[$REGION_INDEX/$TOTAL_REGIONS] Processing region: \033[1;33m$region\033[0m"

    for filter in "${RESOURCE_TYPE_FILTERS[@]}"; do
        # S3 is global — only query once
        if [[ "$filter" == "s3" ]]; then
            if [[ "$S3_QUERIED" == "true" ]]; then
                continue
            fi
            S3_QUERIED=true
            log "  Checking S3 (global)..."
            process_resources "$region" "$filter"
        else
            _type_label=$(get_resource_type_label "$filter")
            log "  Checking $_type_label..."
            process_resources "$region" "$filter"
        fi
    done

    log "  Region $region complete."
done

# --- Summary ---
log ""
log "═══════════════════════════════════════════════════════════════════"
log "  TAGGING COMPLIANCE SUMMARY"
log "═══════════════════════════════════════════════════════════════════"
log ""
printf >&2 "  %-15s %10s %15s %15s\n" "Resource Type" "Count" "Non-Compliant" "Compliance %"
printf >&2 "  %-15s %10s %15s %15s\n" "─────────────" "─────" "─────────────" "────────────"

OVERALL_COUNT=0
OVERALL_COMPLIANCE_SUM=0

for filter in "${RESOURCE_TYPE_FILTERS[@]}"; do
    _type_label=$(get_resource_type_label "$filter")
    _stats_key="${filter//[:\/]/_}"

    _count=$(cat "${STATS_DIR}/${_stats_key}_count")
    _noncompliant=$(cat "${STATS_DIR}/${_stats_key}_noncompliant")
    _compliance_sum=$(cat "${STATS_DIR}/${_stats_key}_compliance_sum")

    if [[ "$_count" -gt 0 ]]; then
        _avg_compliance=$(echo "scale=1; $_compliance_sum / $_count" | bc)
        printf >&2 "  %-15s %10s %15s %14s%%\n" "$_type_label" "$_count" "$_noncompliant" "$_avg_compliance"
        OVERALL_COUNT=$((OVERALL_COUNT + _count))
        OVERALL_COMPLIANCE_SUM=$(echo "$OVERALL_COMPLIANCE_SUM + $_compliance_sum" | bc)
    fi
done

log ""
if [[ "$OVERALL_COUNT" -gt 0 ]]; then
    OVERALL_PCT=$(echo "scale=1; $OVERALL_COMPLIANCE_SUM / $OVERALL_COUNT" | bc)
    log "  Total resources scanned: $OVERALL_COUNT"
    log "  Overall compliance: ${OVERALL_PCT}%"
else
    log "  No resources found across all types and regions."
fi
log ""
log "═══════════════════════════════════════════════════════════════════"
log "✅ DONE. Report saved to: $OUTPUT_FILE"

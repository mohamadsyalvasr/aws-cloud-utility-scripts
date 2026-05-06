#!/bin/bash
# idle_resources_report.sh
# Detects idle/unused AWS resources that are incurring costs without providing value.
# Identifies: EBS volumes (available), Elastic IPs (unassociated), Lambda (zero invocations),
# RDS (zero connections), ELBs (zero healthy targets or zero requests).

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/idle_resources_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""
PERIOD=2592000 # 30 days in seconds

# Source pricing helper for pricing functions
source ./lib/pricing_helper.sh

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for the analysis period (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for the analysis period (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions to scan. Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

# Add a log function for this script to be self-contained
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# Process command-line arguments
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

START_TIME=$(date -u -d "$START_DATE 00:00:00" +%Y-%m-%dT%H:%M:%SZ)
END_TIME=$(date -u -d "$END_DATE 23:59:59" +%Y-%m-%dT%H:%M:%SZ)

# Calculate days in analysis period
DAYS_IDLE=$(( ( $(date -d "$END_DATE" +%s) - $(date -d "$START_DATE" +%s) ) / 86400 ))
if [ "$DAYS_IDLE" -le 0 ]; then
    DAYS_IDLE=1
fi

# --- Helper Functions ---

# Check if a resource has the KeepAlive=true tag
has_keepalive_tag() {
    local tags_json="$1"
    if [ -z "$tags_json" ] || [ "$tags_json" = "null" ]; then
        echo "false"
        return
    fi
    local keepalive
    keepalive=$(echo "$tags_json" | jq -r '[.[] | select(.Key == "KeepAlive" and .Value == "true")] | length')
    if [ "$keepalive" -gt 0 ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Get the Name tag value from a tags JSON array
get_name_tag() {
    local tags_json="$1"
    if [ -z "$tags_json" ] || [ "$tags_json" = "null" ]; then
        echo "N/A"
        return
    fi
    local name
    name=$(echo "$tags_json" | jq -r '(.[] | select(.Key == "Name") | .Value) // "N/A"')
    echo "${name:-N/A}"
}

# --- Main Script ---
log "🔎 Checking dependencies (aws cli, jq, bc)..."
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 || ! command -v bc >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI, jq, and bc."
    exit 1
fi
log "✅ Dependencies met."

log "📊 Idle Resources Detection (Analysis Period: ${START_DATE} to ${END_DATE}, ${DAYS_IDLE} days)"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Resource Type","Resource ID","Resource Name","Status/Reason","Days Idle","Monthly Cost","Recommended Action","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # =========================================================================
    # 1. EBS Volumes in "available" state (not attached to any instance)
    # =========================================================================
    log "  [EBS] Checking for unattached volumes..."
    EBS_DATA=$(aws ec2 describe-volumes --region "$region" \
        --filters "Name=status,Values=available" \
        --query 'Volumes[]' \
        --output json 2>/dev/null) || EBS_DATA="[]"

    EBS_COUNT=$(echo "$EBS_DATA" | jq 'length')

    if [[ "$EBS_COUNT" -gt 0 ]]; then
        log "  [EBS] Found $EBS_COUNT unattached volume(s)"

        echo "$EBS_DATA" | jq -c '.[]' | while read -r volume; do
            VOLUME_ID=$(echo "$volume" | jq -r '.VolumeId')
            VOLUME_TAGS=$(echo "$volume" | jq -c '.Tags // []')
            VOLUME_NAME=$(get_name_tag "$VOLUME_TAGS")
            VOLUME_SIZE=$(echo "$volume" | jq -r '.Size')
            VOLUME_TYPE=$(echo "$volume" | jq -r '.VolumeType')

            # Check KeepAlive tag
            if [ "$(has_keepalive_tag "$VOLUME_TAGS")" = "true" ]; then
                log "    ⏭️ Skipping $VOLUME_ID (KeepAlive=true)"
                continue
            fi

            # Calculate monthly cost using pricing helper
            PRICE_KEY="${VOLUME_TYPE}_per_gb"
            PRICE_PER_GB=$(get_ebs_price "$PRICE_KEY" "$region") || true
            if [ -z "$PRICE_PER_GB" ]; then
                # Fallback to gp2 pricing if type-specific pricing unavailable
                PRICE_PER_GB=$(get_ebs_price "gp2_per_gb" "$region") || true
                PRICE_PER_GB="${PRICE_PER_GB:-0.10}"
            fi
            MONTHLY_COST=$(echo "$VOLUME_SIZE * $PRICE_PER_GB" | bc -l | xargs printf "%.2f")

            REASON="Volume in available state (not attached)"
            RECOMMENDED_ACTION="Create snapshot and delete"

            printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "EBS" \
                "$VOLUME_ID" \
                "$VOLUME_NAME" \
                "$REASON" \
                "$DAYS_IDLE" \
                "$MONTHLY_COST" \
                "$RECOMMENDED_ACTION" \
                "$region" >> "$OUTPUT_FILE"

            log "    💰 $VOLUME_ID ($VOLUME_TYPE, ${VOLUME_SIZE}GiB) - \$${MONTHLY_COST}/month"
        done
    else
        log "  [EBS] No unattached volumes found."
    fi

    # =========================================================================
    # 2. Elastic IP addresses not associated with any running instance
    # =========================================================================
    log "  [EIP] Checking for unassociated Elastic IPs..."
    EIP_DATA=$(aws ec2 describe-addresses --region "$region" \
        --query 'Addresses[]' \
        --output json 2>/dev/null) || EIP_DATA="[]"

    echo "$EIP_DATA" | jq -c '.[] | select(.AssociationId == null or .AssociationId == "")' | while read -r eip; do
        ALLOCATION_ID=$(echo "$eip" | jq -r '.AllocationId')
        PUBLIC_IP=$(echo "$eip" | jq -r '.PublicIp')
        EIP_TAGS=$(echo "$eip" | jq -c '.Tags // []')
        EIP_NAME=$(get_name_tag "$EIP_TAGS")

        # Check KeepAlive tag
        if [ "$(has_keepalive_tag "$EIP_TAGS")" = "true" ]; then
            log "    ⏭️ Skipping $ALLOCATION_ID (KeepAlive=true)"
            continue
        fi

        # Unused EIP charge: $3.60/month
        MONTHLY_COST="3.60"
        REASON="EIP not associated with any instance"
        RECOMMENDED_ACTION="Release EIP"

        printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
            "EIP" \
            "$ALLOCATION_ID" \
            "${EIP_NAME} (${PUBLIC_IP})" \
            "$REASON" \
            "$DAYS_IDLE" \
            "$MONTHLY_COST" \
            "$RECOMMENDED_ACTION" \
            "$region" >> "$OUTPUT_FILE"

        log "    💰 $ALLOCATION_ID ($PUBLIC_IP) - \$${MONTHLY_COST}/month"
    done

    # =========================================================================
    # 3. Lambda functions with zero invocations during analysis period
    # =========================================================================
    log "  [Lambda] Checking for idle Lambda functions..."
    LAMBDA_DATA=$(aws lambda list-functions --region "$region" \
        --query 'Functions[]' \
        --output json 2>/dev/null) || LAMBDA_DATA="[]"

    LAMBDA_COUNT=$(echo "$LAMBDA_DATA" | jq 'length')

    if [[ "$LAMBDA_COUNT" -gt 0 ]]; then
        log "  [Lambda] Checking $LAMBDA_COUNT function(s) for invocations..."

        echo "$LAMBDA_DATA" | jq -c '.[]' | while read -r func; do
            FUNC_NAME=$(echo "$func" | jq -r '.FunctionName')
            FUNC_ARN=$(echo "$func" | jq -r '.FunctionArn')

            # Check tags for KeepAlive
            FUNC_TAGS=$(aws lambda list-tags --region "$region" \
                --resource "$FUNC_ARN" \
                --query 'Tags' \
                --output json 2>/dev/null) || FUNC_TAGS="{}"

            # Lambda tags are key-value object, not array
            KEEPALIVE_VAL=$(echo "$FUNC_TAGS" | jq -r '.KeepAlive // ""')
            if [ "$KEEPALIVE_VAL" = "true" ]; then
                log "    ⏭️ Skipping $FUNC_NAME (KeepAlive=true)"
                continue
            fi

            # Check CloudWatch Invocations metric
            INVOCATIONS=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/Lambda \
                --metric-name Invocations \
                --dimensions Name=FunctionName,Value="$FUNC_NAME" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[].Sum" \
                --output json 2>/dev/null) || INVOCATIONS="[]"

            TOTAL_INVOCATIONS=$(echo "$INVOCATIONS" | jq '[.[] // 0] | add // 0')

            if [ "$(echo "$TOTAL_INVOCATIONS == 0" | bc -l)" = "1" ]; then
                # Lambda with zero invocations costs $0 but clutters environment
                MONTHLY_COST="0.00"
                REASON="Zero invocations during analysis period"
                RECOMMENDED_ACTION="Delete function"

                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "Lambda" \
                    "$FUNC_NAME" \
                    "$FUNC_NAME" \
                    "$REASON" \
                    "$DAYS_IDLE" \
                    "$MONTHLY_COST" \
                    "$RECOMMENDED_ACTION" \
                    "$region" >> "$OUTPUT_FILE"

                log "    🔍 $FUNC_NAME - zero invocations"
            fi
        done
    else
        log "  [Lambda] No Lambda functions found."
    fi

    # =========================================================================
    # 4. RDS instances with zero database connections during analysis period
    # =========================================================================
    log "  [RDS] Checking for idle RDS instances..."
    RDS_DATA=$(aws rds describe-db-instances --region "$region" \
        --query 'DBInstances[]' \
        --output json 2>/dev/null) || RDS_DATA="[]"

    RDS_COUNT=$(echo "$RDS_DATA" | jq 'length')

    if [[ "$RDS_COUNT" -gt 0 ]]; then
        log "  [RDS] Checking $RDS_COUNT instance(s) for connections..."

        echo "$RDS_DATA" | jq -c '.[]' | while read -r rds_instance; do
            DB_INSTANCE_ID=$(echo "$rds_instance" | jq -r '.DBInstanceIdentifier')
            DB_INSTANCE_CLASS=$(echo "$rds_instance" | jq -r '.DBInstanceClass')
            DB_INSTANCE_ARN=$(echo "$rds_instance" | jq -r '.DBInstanceArn')

            # Check tags for KeepAlive
            RDS_TAGS=$(aws rds list-tags-for-resource --region "$region" \
                --resource-name "$DB_INSTANCE_ARN" \
                --query 'TagList' \
                --output json 2>/dev/null) || RDS_TAGS="[]"

            if [ "$(has_keepalive_tag "$RDS_TAGS")" = "true" ]; then
                log "    ⏭️ Skipping $DB_INSTANCE_ID (KeepAlive=true)"
                continue
            fi

            RDS_NAME=$(get_name_tag "$RDS_TAGS")

            # Check CloudWatch DatabaseConnections metric
            CONNECTIONS=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/RDS \
                --metric-name DatabaseConnections \
                --dimensions Name=DBInstanceIdentifier,Value="$DB_INSTANCE_ID" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[].Sum" \
                --output json 2>/dev/null) || CONNECTIONS="[]"

            TOTAL_CONNECTIONS=$(echo "$CONNECTIONS" | jq '[.[] // 0] | add // 0')

            if [ "$(echo "$TOTAL_CONNECTIONS == 0" | bc -l)" = "1" ]; then
                # Calculate monthly cost using pricing helper
                HOURLY_PRICE=$(get_rds_price "$DB_INSTANCE_CLASS" "$region") || true
                if [ -n "$HOURLY_PRICE" ]; then
                    MONTHLY_COST=$(echo "$HOURLY_PRICE * 730" | bc -l | xargs printf "%.2f")
                else
                    MONTHLY_COST="N/A"
                fi

                REASON="Zero database connections during analysis period"
                RECOMMENDED_ACTION="Stop or terminate instance"

                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "RDS" \
                    "$DB_INSTANCE_ID" \
                    "${RDS_NAME}" \
                    "$REASON" \
                    "$DAYS_IDLE" \
                    "$MONTHLY_COST" \
                    "$RECOMMENDED_ACTION" \
                    "$region" >> "$OUTPUT_FILE"

                log "    💰 $DB_INSTANCE_ID ($DB_INSTANCE_CLASS) - \$${MONTHLY_COST}/month"
            fi
        done
    else
        log "  [RDS] No RDS instances found."
    fi

    # =========================================================================
    # 5. Elastic Load Balancers (ALB/NLB) with zero healthy targets or zero requests
    # =========================================================================
    log "  [ELB] Checking for idle load balancers..."
    ELB_DATA=$(aws elbv2 describe-load-balancers --region "$region" \
        --query 'LoadBalancers[]' \
        --output json 2>/dev/null) || ELB_DATA="[]"

    ELB_COUNT=$(echo "$ELB_DATA" | jq 'length')

    if [[ "$ELB_COUNT" -gt 0 ]]; then
        log "  [ELB] Checking $ELB_COUNT load balancer(s)..."

        echo "$ELB_DATA" | jq -c '.[]' | while read -r elb; do
            LB_ARN=$(echo "$elb" | jq -r '.LoadBalancerArn')
            LB_NAME=$(echo "$elb" | jq -r '.LoadBalancerName')
            LB_TYPE=$(echo "$elb" | jq -r '.Type')

            # Extract the ARN suffix for CloudWatch dimension
            # Format: app/my-lb-name/1234567890abcdef or net/my-lb-name/1234567890abcdef
            LB_ARN_SUFFIX=$(echo "$LB_ARN" | sed 's|.*:loadbalancer/||')

            # Check tags for KeepAlive
            ELB_TAGS=$(aws elbv2 describe-tags --region "$region" \
                --resource-arns "$LB_ARN" \
                --query 'TagDescriptions[0].Tags' \
                --output json 2>/dev/null) || ELB_TAGS="[]"

            if [ "$(has_keepalive_tag "$ELB_TAGS")" = "true" ]; then
                log "    ⏭️ Skipping $LB_NAME (KeepAlive=true)"
                continue
            fi

            IS_IDLE="false"
            IDLE_REASON=""

            # Check RequestCount metric (works for both ALB and NLB)
            REQUEST_COUNT=$(aws cloudwatch get-metric-statistics --region "$region" \
                --namespace AWS/ApplicationELB \
                --metric-name RequestCount \
                --dimensions Name=LoadBalancer,Value="$LB_ARN_SUFFIX" \
                --start-time "$START_TIME" \
                --end-time "$END_TIME" \
                --period "$PERIOD" \
                --statistics Sum \
                --query "Datapoints[].Sum" \
                --output json 2>/dev/null) || REQUEST_COUNT="[]"

            TOTAL_REQUESTS=$(echo "$REQUEST_COUNT" | jq '[.[] // 0] | add // 0')

            if [ "$(echo "$TOTAL_REQUESTS == 0" | bc -l)" = "1" ]; then
                IS_IDLE="true"
                IDLE_REASON="Zero request count during analysis period"
            fi

            # Also check HealthyHostCount if not already flagged
            if [ "$IS_IDLE" = "false" ]; then
                HEALTHY_HOSTS=$(aws cloudwatch get-metric-statistics --region "$region" \
                    --namespace AWS/ApplicationELB \
                    --metric-name HealthyHostCount \
                    --dimensions Name=LoadBalancer,Value="$LB_ARN_SUFFIX" \
                    --start-time "$START_TIME" \
                    --end-time "$END_TIME" \
                    --period "$PERIOD" \
                    --statistics Average \
                    --query "Datapoints[].Average" \
                    --output json 2>/dev/null) || HEALTHY_HOSTS="[]"

                AVG_HEALTHY=$(echo "$HEALTHY_HOSTS" | jq '[.[] // 0] | if length > 0 then (add / length) else 0 end')

                if [ "$(echo "$AVG_HEALTHY == 0" | bc -l)" = "1" ]; then
                    IS_IDLE="true"
                    IDLE_REASON="Zero healthy targets during analysis period"
                fi
            fi

            if [ "$IS_IDLE" = "true" ]; then
                # Monthly cost estimate based on LB type
                if [ "$LB_TYPE" = "application" ]; then
                    MONTHLY_COST="16.20"
                else
                    # NLB or Gateway LB
                    MONTHLY_COST="22.50"
                fi

                RECOMMENDED_ACTION="Delete load balancer"

                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "ELB" \
                    "$LB_NAME" \
                    "$LB_NAME" \
                    "$IDLE_REASON" \
                    "$DAYS_IDLE" \
                    "$MONTHLY_COST" \
                    "$RECOMMENDED_ACTION" \
                    "$region" >> "$OUTPUT_FILE"

                log "    💰 $LB_NAME ($LB_TYPE) - \$${MONTHLY_COST}/month - $IDLE_REASON"
            fi
        done
    else
        log "  [ELB] No load balancers found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Idle Resources report saved to: $OUTPUT_FILE"

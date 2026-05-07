#!/bin/bash
# resource_lifecycle_report.sh
# Identifies AWS resources that are old, outdated, or using deprecated configurations.
# Checks: EC2 AMI staleness, RDS maintenance gaps, Lambda deprecated runtimes,
# EKS outdated Kubernetes versions, and general resource age.
# Produces a CSV report sorted by age descending with actionable recommendations.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/resource_lifecycle_report.csv"

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
                   Default: resource_lifecycle_report.csv
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

# --- Parse RESOURCE_AGE_THRESHOLD ---
RAW_THRESHOLD="${RESOURCE_AGE_THRESHOLD:-365}"
if [[ "$RAW_THRESHOLD" =~ ^[0-9]+$ ]]; then
    AGE_THRESHOLD="$RAW_THRESHOLD"
else
    log "⚠️  RESOURCE_AGE_THRESHOLD ('$RAW_THRESHOLD') is not numeric. Falling back to default: 365"
    AGE_THRESHOLD=365
fi
log "📋 Age threshold: ${AGE_THRESHOLD} days"

# --- Deprecated Runtimes ---
DEPRECATED_RUNTIMES=("python3.8" "python3.9" "nodejs14.x" "nodejs16.x" "dotnet6" "java8" "ruby2.7" "go1.x")

# --- EKS Supported Versions (latest 2 minor versions) ---
EKS_SUPPORTED_VERSIONS=("1.30" "1.31")
EKS_LATEST_VERSION="1.31"

# --- Setup ---
mkdir -p "${OUTPUT_DIR}"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Resource Type","Resource ID","Resource Name","Age (Days)","Issue","Recommendation","Region"\n' > "$OUTPUT_FILE"

# Temp file for findings (will be sorted before final output)
FINDINGS_FILE=$(mktemp)
REPORTED_IDS_FILE=$(mktemp)
trap 'rm -f "$FINDINGS_FILE" "$REPORTED_IDS_FILE"' EXIT

# --- Helper: days_since() ---
# Calculates the number of days between a given ISO date and today.
# Usage: days_since "2023-01-15T10:30:00Z"
days_since() {
    local input_date="$1"
    local today_epoch
    local input_epoch

    today_epoch=$(date +%s)
    input_epoch=$(date -d "$input_date" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${input_date%%.*}" +%s 2>/dev/null || echo "0")

    if [[ "$input_epoch" == "0" ]]; then
        echo "0"
        return
    fi

    local diff_seconds=$((today_epoch - input_epoch))
    local diff_days=$((diff_seconds / 86400))
    echo "$diff_days"
}

# --- Helper: mark resource as reported ---
mark_reported() {
    local resource_id="$1"
    echo "$resource_id" >> "$REPORTED_IDS_FILE"
}

# --- Helper: check if resource already reported ---
is_reported() {
    local resource_id="$1"
    grep -qxF "$resource_id" "$REPORTED_IDS_FILE" 2>/dev/null
}

# --- Helper: append finding ---
append_finding() {
    local resource_type="$1"
    local resource_id="$2"
    local resource_name="$3"
    local age_days="$4"
    local issue="$5"
    local recommendation="$6"
    local region="$7"

    printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
        "$resource_type" \
        "$resource_id" \
        "$resource_name" \
        "$age_days" \
        "$issue" \
        "$recommendation" \
        "$region" >> "$FINDINGS_FILE"
}

# =============================================================================
# CHECK 1: EC2 AMI Staleness
# =============================================================================
check_ec2_ami_staleness() {
    local region="$1"
    log "  [EC2 AMI] Checking AMI staleness..."

    local instances_json
    instances_json=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[]' \
        --output json 2>/dev/null) || {
        log "  ⚠️ EC2 describe-instances failed in $region. Skipping."
        return 0
    }

    local instance_count
    instance_count=$(echo "$instances_json" | jq 'length')

    if [[ "$instance_count" -eq 0 || "$instances_json" == "null" ]]; then
        log "  [EC2 AMI] No running instances found."
        return 0
    fi

    local i=0
    while [[ $i -lt $instance_count ]]; do
        local instance
        instance=$(echo "$instances_json" | jq -c ".[$i]")

        local instance_id
        instance_id=$(echo "$instance" | jq -r '.InstanceId')

        local instance_name
        instance_name=$(echo "$instance" | jq -r '(.Tags // [])[] | select(.Key == "Name") | .Value' 2>/dev/null || echo "")
        if [[ -z "$instance_name" ]]; then
            instance_name="N/A"
        fi

        local launch_time
        launch_time=$(echo "$instance" | jq -r '.LaunchTime')

        local image_id
        image_id=$(echo "$instance" | jq -r '.ImageId')

        local instance_age
        instance_age=$(days_since "$launch_time")

        # Check AMI details
        local ami_json
        ami_json=$(aws ec2 describe-images \
            --region "$region" \
            --image-ids "$image_id" \
            --output json 2>/dev/null) || ami_json=""

        local ami_count=0
        if [[ -n "$ami_json" ]]; then
            ami_count=$(echo "$ami_json" | jq '.Images | length' 2>/dev/null || echo "0")
        fi

        if [[ "$ami_count" -eq 0 ]]; then
            # AMI deregistered
            append_finding "EC2" "$instance_id" "$instance_name" "$instance_age" \
                "AMI deregistered - source image no longer available" \
                "Consider relaunching with an updated AMI" "$region"
            mark_reported "$instance_id"
        else
            local ami_creation_date
            ami_creation_date=$(echo "$ami_json" | jq -r '.Images[0].CreationDate')
            local ami_age
            ami_age=$(days_since "$ami_creation_date")

            if [[ "$instance_age" -gt "$AGE_THRESHOLD" && "$ami_age" -gt "$AGE_THRESHOLD" ]]; then
                append_finding "EC2" "$instance_id" "$instance_name" "$instance_age" \
                    "Stale AMI - instance running > ${AGE_THRESHOLD} days without AMI update" \
                    "Consider relaunching with an updated AMI" "$region"
                mark_reported "$instance_id"
            fi
        fi

        i=$((i + 1))
    done

    log "  [EC2 AMI] Checked $instance_count instances."
}

# =============================================================================
# CHECK 2: RDS Maintenance
# =============================================================================
check_rds_maintenance() {
    local region="$1"
    log "  [RDS] Checking maintenance status..."

    local rds_json
    rds_json=$(aws rds describe-db-instances \
        --region "$region" \
        --query 'DBInstances[]' \
        --output json 2>/dev/null) || {
        log "  ⚠️ RDS describe-db-instances failed in $region. Skipping."
        return 0
    }

    local rds_count
    rds_count=$(echo "$rds_json" | jq 'length')

    if [[ "$rds_count" -eq 0 || "$rds_json" == "null" ]]; then
        log "  [RDS] No RDS instances found."
        return 0
    fi

    # Get pending maintenance actions
    local maintenance_json
    maintenance_json=$(aws rds describe-pending-maintenance-actions \
        --region "$region" \
        --output json 2>/dev/null) || maintenance_json='{"PendingMaintenanceActions":[]}'

    local i=0
    while [[ $i -lt $rds_count ]]; do
        local db_instance
        db_instance=$(echo "$rds_json" | jq -c ".[$i]")

        local db_id
        db_id=$(echo "$db_instance" | jq -r '.DBInstanceIdentifier')

        local db_name
        db_name="$db_id"

        local create_time
        create_time=$(echo "$db_instance" | jq -r '.InstanceCreateTime')

        local db_age
        db_age=$(days_since "$create_time")

        local db_arn
        db_arn=$(echo "$db_instance" | jq -r '.DBInstanceArn')

        # Check for pending maintenance on this instance
        local pending_actions
        pending_actions=$(echo "$maintenance_json" | jq -c \
            --arg arn "$db_arn" \
            '.PendingMaintenanceActions[] | select(.ResourceIdentifier == $arn) | .PendingMaintenanceActionDetails[]' 2>/dev/null || echo "")

        local has_pending=false
        if [[ -n "$pending_actions" ]]; then
            # Report each pending action
            echo "$pending_actions" | while IFS= read -r action; do
                local action_desc
                action_desc=$(echo "$action" | jq -r '.Action // "unknown"')
                append_finding "RDS" "$db_id" "$db_name" "$db_age" \
                    "Pending maintenance action: $action_desc" \
                    "Apply pending maintenance" "$region"
            done
            has_pending=true
            mark_reported "$db_id"
        fi

        # If instance is older than 180 days with no pending maintenance
        if [[ "$has_pending" == "false" && "$db_age" -gt 180 ]]; then
            append_finding "RDS" "$db_id" "$db_name" "$db_age" \
                "No recent maintenance - instance age exceeds 180 days" \
                "Review maintenance schedule and apply updates" "$region"
            mark_reported "$db_id"
        fi

        i=$((i + 1))
    done

    log "  [RDS] Checked $rds_count instances."
}

# =============================================================================
# CHECK 3: Lambda Deprecated Runtimes
# =============================================================================
check_lambda_runtimes() {
    local region="$1"
    log "  [Lambda] Checking for deprecated runtimes..."

    local lambda_json
    lambda_json=$(aws lambda list-functions \
        --region "$region" \
        --query 'Functions[]' \
        --output json 2>/dev/null) || {
        log "  ⚠️ Lambda list-functions failed in $region. Skipping."
        return 0
    }

    local lambda_count
    lambda_count=$(echo "$lambda_json" | jq 'length')

    if [[ "$lambda_count" -eq 0 || "$lambda_json" == "null" ]]; then
        log "  [Lambda] No functions found."
        return 0
    fi

    local i=0
    while [[ $i -lt $lambda_count ]]; do
        local func
        func=$(echo "$lambda_json" | jq -c ".[$i]")

        local func_name
        func_name=$(echo "$func" | jq -r '.FunctionName')

        local func_arn
        func_arn=$(echo "$func" | jq -r '.FunctionArn')

        local runtime
        runtime=$(echo "$func" | jq -r '.Runtime // "N/A"')

        local last_modified
        last_modified=$(echo "$func" | jq -r '.LastModified')

        local func_age
        func_age=$(days_since "$last_modified")

        # Check if runtime is deprecated
        for deprecated in "${DEPRECATED_RUNTIMES[@]}"; do
            if [[ "$runtime" == "$deprecated" ]]; then
                append_finding "Lambda" "$func_name" "$func_name" "$func_age" \
                    "Deprecated runtime: $runtime" \
                    "Migrate to a supported runtime version" "$region"
                mark_reported "$func_arn"
                mark_reported "$func_name"
                break
            fi
        done

        i=$((i + 1))
    done

    log "  [Lambda] Checked $lambda_count functions."
}

# =============================================================================
# CHECK 4: EKS Outdated Versions
# =============================================================================
check_eks_versions() {
    local region="$1"
    log "  [EKS] Checking Kubernetes versions..."

    local clusters_json
    clusters_json=$(aws eks list-clusters \
        --region "$region" \
        --query 'clusters' \
        --output json 2>/dev/null) || {
        log "  ⚠️ EKS list-clusters failed in $region. Skipping."
        return 0
    }

    local cluster_count
    cluster_count=$(echo "$clusters_json" | jq 'length')

    if [[ "$cluster_count" -eq 0 || "$clusters_json" == "null" ]]; then
        log "  [EKS] No clusters found."
        return 0
    fi

    local i=0
    while [[ $i -lt $cluster_count ]]; do
        local cluster_name
        cluster_name=$(echo "$clusters_json" | jq -r ".[$i]")

        local cluster_details
        cluster_details=$(aws eks describe-cluster \
            --region "$region" \
            --name "$cluster_name" \
            --output json 2>/dev/null) || {
            log "  ⚠️ Failed to describe cluster $cluster_name. Skipping."
            i=$((i + 1))
            continue
        }

        local k8s_version
        k8s_version=$(echo "$cluster_details" | jq -r '.cluster.version')

        local created_at
        created_at=$(echo "$cluster_details" | jq -r '.cluster.createdAt')

        local cluster_age
        cluster_age=$(days_since "$created_at")

        # Check if version is in the latest 2 supported versions
        local is_supported=false
        for supported in "${EKS_SUPPORTED_VERSIONS[@]}"; do
            if [[ "$k8s_version" == "$supported" ]]; then
                is_supported=true
                break
            fi
        done

        if [[ "$is_supported" == "false" ]]; then
            append_finding "EKS" "$cluster_name" "$cluster_name" "$cluster_age" \
                "Outdated Kubernetes version: $k8s_version" \
                "Upgrade to Kubernetes $EKS_LATEST_VERSION" "$region"
            mark_reported "$cluster_name"
        fi

        i=$((i + 1))
    done

    log "  [EKS] Checked $cluster_count clusters."
}

# =============================================================================
# CHECK 5: General Resource Age
# =============================================================================
check_general_age() {
    local region="$1"
    log "  [General] Checking resource age..."

    # --- EC2 Instances ---
    local ec2_json
    ec2_json=$(aws ec2 describe-instances \
        --region "$region" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[]' \
        --output json 2>/dev/null) || ec2_json="[]"

    if [[ "$ec2_json" != "null" && "$ec2_json" != "[]" ]]; then
        local ec2_count
        ec2_count=$(echo "$ec2_json" | jq 'length')
        local i=0
        while [[ $i -lt $ec2_count ]]; do
            local instance
            instance=$(echo "$ec2_json" | jq -c ".[$i]")

            local instance_id
            instance_id=$(echo "$instance" | jq -r '.InstanceId')

            if ! is_reported "$instance_id"; then
                local instance_name
                instance_name=$(echo "$instance" | jq -r '(.Tags // [])[] | select(.Key == "Name") | .Value' 2>/dev/null || echo "")
                if [[ -z "$instance_name" ]]; then
                    instance_name="N/A"
                fi

                local launch_time
                launch_time=$(echo "$instance" | jq -r '.LaunchTime')

                local instance_age
                instance_age=$(days_since "$launch_time")

                if [[ "$instance_age" -gt "$AGE_THRESHOLD" ]]; then
                    append_finding "EC2" "$instance_id" "$instance_name" "$instance_age" \
                        "Resource age exceeds ${AGE_THRESHOLD} days - review recommended" \
                        "Review resource necessity and configuration" "$region"
                    mark_reported "$instance_id"
                fi
            fi

            i=$((i + 1))
        done
    fi

    # --- RDS Instances ---
    local rds_json
    rds_json=$(aws rds describe-db-instances \
        --region "$region" \
        --query 'DBInstances[]' \
        --output json 2>/dev/null) || rds_json="[]"

    if [[ "$rds_json" != "null" && "$rds_json" != "[]" ]]; then
        local rds_count
        rds_count=$(echo "$rds_json" | jq 'length')
        local i=0
        while [[ $i -lt $rds_count ]]; do
            local db_instance
            db_instance=$(echo "$rds_json" | jq -c ".[$i]")

            local db_id
            db_id=$(echo "$db_instance" | jq -r '.DBInstanceIdentifier')

            if ! is_reported "$db_id"; then
                local create_time
                create_time=$(echo "$db_instance" | jq -r '.InstanceCreateTime')

                local db_age
                db_age=$(days_since "$create_time")

                if [[ "$db_age" -gt "$AGE_THRESHOLD" ]]; then
                    append_finding "RDS" "$db_id" "$db_id" "$db_age" \
                        "Resource age exceeds ${AGE_THRESHOLD} days - review recommended" \
                        "Review resource necessity and configuration" "$region"
                    mark_reported "$db_id"
                fi
            fi

            i=$((i + 1))
        done
    fi

    # --- Lambda Functions ---
    local lambda_json
    lambda_json=$(aws lambda list-functions \
        --region "$region" \
        --query 'Functions[]' \
        --output json 2>/dev/null) || lambda_json="[]"

    if [[ "$lambda_json" != "null" && "$lambda_json" != "[]" ]]; then
        local lambda_count
        lambda_count=$(echo "$lambda_json" | jq 'length')
        local i=0
        while [[ $i -lt $lambda_count ]]; do
            local func
            func=$(echo "$lambda_json" | jq -c ".[$i]")

            local func_name
            func_name=$(echo "$func" | jq -r '.FunctionName')

            local func_arn
            func_arn=$(echo "$func" | jq -r '.FunctionArn')

            if ! is_reported "$func_name" && ! is_reported "$func_arn"; then
                local last_modified
                last_modified=$(echo "$func" | jq -r '.LastModified')

                local func_age
                func_age=$(days_since "$last_modified")

                if [[ "$func_age" -gt "$AGE_THRESHOLD" ]]; then
                    append_finding "Lambda" "$func_name" "$func_name" "$func_age" \
                        "Resource age exceeds ${AGE_THRESHOLD} days - review recommended" \
                        "Review resource necessity and configuration" "$region"
                    mark_reported "$func_name"
                fi
            fi

            i=$((i + 1))
        done
    fi

    log "  [General] Age check complete."
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
TOTAL_REGIONS=${#REGIONS[@]}
REGION_INDEX=0

for region in "${REGIONS[@]}"; do
    REGION_INDEX=$((REGION_INDEX + 1))
    log "[$REGION_INDEX/$TOTAL_REGIONS] Processing region: \033[1;33m$region\033[0m"

    check_ec2_ami_staleness "$region"
    check_rds_maintenance "$region"
    check_lambda_runtimes "$region"
    check_eks_versions "$region"
    check_general_age "$region"

    log "  Region $region complete."
done

# --- Sort findings by Age (Days) descending and append to output ---
if [[ -s "$FINDINGS_FILE" ]]; then
    # Sort by 4th field (Age) numerically in reverse order
    sort -t',' -k4 -nr "$FINDINGS_FILE" >> "$OUTPUT_FILE"
fi

# --- Summary ---
TOTAL_FINDINGS=0
if [[ -s "$FINDINGS_FILE" ]]; then
    TOTAL_FINDINGS=$(wc -l < "$FINDINGS_FILE" | tr -d ' ')
fi

log ""
log "═══════════════════════════════════════════════════════════════════"
log "  RESOURCE LIFECYCLE REPORT SUMMARY"
log "═══════════════════════════════════════════════════════════════════"
log ""
log "  Total findings: $TOTAL_FINDINGS"
log "  Age threshold:  ${AGE_THRESHOLD} days"
log "  Regions:        ${REGIONS[*]}"
log ""
log "═══════════════════════════════════════════════════════════════════"
log "✅ DONE. Report saved to: $OUTPUT_FILE"

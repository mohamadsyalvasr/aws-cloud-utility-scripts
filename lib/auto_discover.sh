#!/bin/bash
# lib/auto_discover.sh
# Auto-discovers active AWS services from Cost Explorer billing data
# and enables corresponding report config keys.
#
# Usage: source this file, then call auto_discover_services
# It will set config variables (ec2=1, rds=1, etc.) for services found in billing.

# Pattern mapping: Cost Explorer service name keywords → config keys to enable
# Multiple config keys can be enabled by one pattern (space-separated)
declare -A SERVICE_PATTERNS=(
    ["Elastic Compute Cloud"]="ec2 ebs_detailed"
    ["EC2 - Other"]="ec2 ebs_detailed ebs_utilization natgateway"
    ["EC2-Other"]="ec2 ebs_detailed ebs_utilization natgateway"
    ["Elastic Block Store"]="ebs_detailed ebs_utilization"
    ["Relational Database"]="rds"
    ["Simple Storage Service"]="s3"
    ["Lambda"]="lambda"
    ["Elastic Load Balancing"]="elb"
    ["Elastic Container Service"]="ecs"
    ["Elastic Kubernetes"]="eks"
    ["CloudFront"]="cloudfront"
    ["DynamoDB"]="dynamodb"
    ["ElastiCache"]="elasticache"
    ["Route 53"]="route53"
    ["Simple Notification Service"]="sns"
    ["Simple Queue Service"]="sqs"
    ["Glue"]="glue"
    ["Key Management Service"]="kms"
    ["Virtual Private Cloud"]="vpc vpn"
    ["VPC"]="vpc vpn natgateway transitgateway"
    ["Elastic File System"]="efs"
    ["SageMaker"]="sagemaker"
    ["Bedrock"]="bedrock"
    ["Lightsail"]="lightsail"
    ["WorkSpaces"]="workspaces"
    ["CloudWatch"]="cloudwatch"
    ["Backup"]="backup"
    ["Certificate Manager"]="acm"
    ["Secrets Manager"]="secrets_manager"
    ["Step Functions"]="stepfunctions"
    ["API Gateway"]="apigateway"
    ["Kinesis"]="kinesis"
    ["Redshift"]="redshift"
    ["OpenSearch"]="opensearch"
    ["CodePipeline"]="codepipeline"
    ["Systems Manager"]="ssm_params"
    ["EventBridge"]="eventbridge"
    ["Config"]="config"
    ["Direct Connect"]="directconnect"
    ["DocumentDB"]="documentdb"
    ["Managed Streaming"]="msk"
    ["MSK"]="msk"
    ["Cognito"]="cognito"
    ["App Runner"]="apprunner"
    ["MQ"]="mq"
    ["Amazon MQ"]="mq"
    ["Neptune"]="neptune"
    ["Grafana"]="grafana"
    ["Transfer Family"]="transfer_family"
    ["Transfer"]="transfer_family"
    ["Container Registry"]="ecr"
    ["Simple Email Service"]="ses"
    ["Data Transfer"]="data_transfer"
    ["NAT Gateway"]="natgateway"
    ["Transit Gateway"]="transitgateway"
    ["IAM"]="iam"
    ["Savings Plans"]="sp"
    ["Reserved"]="ri"
    ["WAF"]="waf"
    ["AWS WAF"]="waf"
    ["GuardDuty"]="sec_logging_audit"
    ["FSx"]="SKIP"
    ["Amplify"]="SKIP"
    ["CloudShell"]="SKIP"
    ["DataSync"]="SKIP"
    ["QuickSight"]="SKIP"
    ["Tax"]="SKIP"
)

auto_discover_services() {
    local start_date="${1:-$START_DATE}"
    local end_date="${2:-$END_DATE}"

    # Validate dates
    if [[ -z "$start_date" || -z "$end_date" ]]; then
        log_error "auto_discover_services requires start and end dates"
        return 1
    fi

    log_start "🔍 Auto-discovering active services from billing data..."
    log_start "   Period: $start_date to $end_date"

    # Query Cost Explorer for services with non-zero cost
    local ce_result
    set +e
    ce_result=$(aws ce get-cost-and-usage \
        --time-period Start="$start_date",End="$end_date" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE \
        --output json 2>&1)
    local ce_exit=$?
    set -e

    if [[ $ce_exit -ne 0 ]]; then
        if echo "$ce_result" | grep -qi "AccessDenied"; then
            log_error "Cost Explorer AccessDenied. Cannot auto-discover services."
            log_error "Falling back to config.ini settings."
            return 1
        else
            log_error "Cost Explorer error: $ce_result"
            log_error "Falling back to config.ini settings."
            return 1
        fi
    fi

    # Extract service names with non-zero cost
    local services
    services=$(echo "$ce_result" | jq -r '
        [.ResultsByTime[].Groups[] | 
         select((.Metrics.UnblendedCost.Amount | tonumber) > 0) |
         .Keys[0]] | unique | .[]
    ' 2>/dev/null)

    if [[ -z "$services" ]]; then
        log_start "   ⚠️ No services with cost found in billing data."
        return 1
    fi

    local service_count
    service_count=$(echo "$services" | wc -l | tr -d '[:space:]')
    log_start "   Found $service_count active service(s) in billing"

    # Track which config keys get enabled
    local enabled_keys=()
    # Track services that have no matching pattern (unmapped)
    local unmapped_services=()
    # File to store key=value pairs for sourcing after function returns
    local keys_file="${OUTPUT_DIR}/.discovered_keys"
    : > "$keys_file"  # Create/truncate

    # Match each billing service against patterns
    while IFS= read -r service_name; do
        [[ -z "$service_name" ]] && continue

        local matched=false
        for pattern in "${!SERVICE_PATTERNS[@]}"; do
            if echo "$service_name" | grep -qi "$pattern"; then
                matched=true
                # Enable all config keys for this pattern
                local keys="${SERVICE_PATTERNS[$pattern]}"
                # Skip services marked as SKIP (known billing items without report scripts)
                if [[ "$keys" == "SKIP" ]]; then
                    continue
                fi
                for key in $keys; do
                    echo "${key}=1" >> "$keys_file"
                    enabled_keys+=("$key")
                done
            fi
        done

        # Track unmapped services (in billing but no report script available)
        if [[ "$matched" == "false" ]]; then
            unmapped_services+=("$service_name")
        fi
    done <<< "$services"

    # Source the discovered keys file to set variables in the calling shell
    if [[ -s "$keys_file" ]]; then
        # Deduplicate and source
        sort -u "$keys_file" > "${keys_file}.tmp" && mv "${keys_file}.tmp" "$keys_file"
        source "$keys_file"
        # Also export them
        while IFS='=' read -r k v; do
            export "$k=$v"
        done < "$keys_file"
    fi

    # Deduplicate and report
    local unique_keys
    unique_keys=$(printf '%s\n' "${enabled_keys[@]}" | sort -u)
    local enabled_count
    enabled_count=$(echo "$unique_keys" | grep -c . || echo "0")

    log_success "Auto-discovery complete: $enabled_count report(s) enabled"
    log_start "   Enabled: $(echo $unique_keys | tr '\n' ' ')"

    # Report unmapped services (in billing but no report available)
    if [[ ${#unmapped_services[@]} -gt 0 ]]; then
        log_start ""
        log_start "   ⚠️  Services found in billing but NO report script available:"
        log_start "   ────────────────────────────────────────────────────────────"
        for svc in "${unmapped_services[@]}"; do
            log_start "     • $svc"
        done
        log_start "   ────────────────────────────────────────────────────────────"
        log_start "   These services are being billed but won't be inventoried."
        log_start "   Consider adding report scripts for them (see docs/adding-reports.md)"
        log_start ""
    fi

    # Always enable billing report itself (since we just proved CE works)
    export billing=1

    # Always enable IAM (global, always relevant)
    export iam=1

    # Export the keys file path so main_report_runner can re-source if needed
    export DISCOVERED_KEYS_FILE="$keys_file"

    return 0
}

# =============================================================================
# Auto-discover active regions from Cost Explorer billing data.
# Sets DISCOVERED_REGIONS variable with comma-separated list of active regions.
# Also creates per-service region mapping file at ${OUTPUT_DIR}/.service_regions
# =============================================================================
auto_discover_regions() {
    local start_date="${1:-$START_DATE}"
    local end_date="${2:-$END_DATE}"

    # Validate dates
    if [[ -z "$start_date" || -z "$end_date" ]]; then
        log_error "auto_discover_regions requires start and end dates"
        return 1
    fi

    log_start "🌍 Auto-discovering active regions per service from billing data..."

    # Query Cost Explorer grouped by SERVICE + REGION (2 dimensions)
    local ce_result
    set +e
    ce_result=$(aws ce get-cost-and-usage \
        --time-period Start="$start_date",End="$end_date" \
        --granularity MONTHLY \
        --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE Type=DIMENSION,Key=REGION \
        --output json 2>&1)
    local ce_exit=$?
    set -e

    if [[ $ce_exit -ne 0 ]]; then
        log_error "Cost Explorer error during region discovery. Using default regions."
        return 1
    fi

    # Extract service+region pairs with non-zero cost
    local pairs
    pairs=$(echo "$ce_result" | jq -r '
        .ResultsByTime[].Groups[] |
        select((.Metrics.UnblendedCost.Amount | tonumber) > 0) |
        "\(.Keys[0])|\(.Keys[1])"
    ' 2>/dev/null)

    if [[ -z "$pairs" ]]; then
        log_start "   ⚠️ No service+region data found. Using default regions."
        return 1
    fi

    # Build per-config-key region mapping
    # Format: config_key=region1,region2,...
    local service_regions_file="${OUTPUT_DIR}/.service_regions"
    local all_regions_file=$(mktemp)
    local mapping_file=$(mktemp)
    trap 'rm -f "$all_regions_file" "$mapping_file"' RETURN

    # Process each service+region pair
    while IFS='|' read -r service_name region_name; do
        [[ -z "$service_name" || -z "$region_name" ]] && continue
        [[ "$region_name" == "global" || "$region_name" == "NoRegion" || "$region_name" == "" ]] && continue

        # Track all regions
        echo "$region_name" >> "$all_regions_file"

        # Map service to config keys using SERVICE_PATTERNS
        for pattern in "${!SERVICE_PATTERNS[@]}"; do
            if echo "$service_name" | grep -qi "$pattern"; then
                local keys="${SERVICE_PATTERNS[$pattern]}"
                for key in $keys; do
                    echo "${key}|${region_name}" >> "$mapping_file"
                done
            fi
        done
    done <<< "$pairs"

    # Build .service_regions file (deduplicated regions per config key)
    {
        echo "# Auto-generated by auto_discover_regions at $(date +'%Y-%m-%d %H:%M:%S')"
        echo "# Format: config_key=region1,region2,..."
        echo "# Scripts will use these regions instead of the global -r flag"
    } > "$service_regions_file"

    # Get unique config keys from mapping
    local config_keys
    config_keys=$(cut -d'|' -f1 "$mapping_file" 2>/dev/null | sort -u)

    local mapped_count=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        # Get unique regions for this key
        local key_regions
        key_regions=$(grep "^${key}|" "$mapping_file" | cut -d'|' -f2 | sort -u | tr '\n' ',' | sed 's/,$//')
        if [[ -n "$key_regions" ]]; then
            echo "${key}=${key_regions}" >> "$service_regions_file"
            mapped_count=$((mapped_count + 1))
        fi
    done <<< "$config_keys"

    # Build global DISCOVERED_REGIONS (all unique regions)
    DISCOVERED_REGIONS=$(sort -u "$all_regions_file" | tr '\n' ',' | sed 's/,$//')
    local region_count
    region_count=$(sort -u "$all_regions_file" | grep -c . || echo "0")

    log_success "Region discovery complete: $region_count region(s), $mapped_count service-region mapping(s)"
    log_start "   All regions: $DISCOVERED_REGIONS"
    log_start "   Per-service mapping: $service_regions_file"

    export DISCOVERED_REGIONS
    export SERVICE_REGIONS_FILE="$service_regions_file"
    return 0
}

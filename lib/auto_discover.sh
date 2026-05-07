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

    # Match each billing service against patterns
    while IFS= read -r service_name; do
        [[ -z "$service_name" ]] && continue

        local matched=false
        for pattern in "${!SERVICE_PATTERNS[@]}"; do
            if echo "$service_name" | grep -qi "$pattern"; then
                matched=true
                # Enable all config keys for this pattern
                local keys="${SERVICE_PATTERNS[$pattern]}"
                for key in $keys; do
                    # Set the variable (export so it's available to build_task_list)
                    eval "export ${key}=1"
                    enabled_keys+=("$key")
                done
            fi
        done

        # Track unmapped services (in billing but no report script available)
        if [[ "$matched" == "false" ]]; then
            unmapped_services+=("$service_name")
        fi
    done <<< "$services"

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

    return 0
}

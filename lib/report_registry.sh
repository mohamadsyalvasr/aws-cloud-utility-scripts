#!/bin/bash
# lib/report_registry.sh
# Registry of all available reports.
# Maps config.ini keys to script paths and their required CLI arguments.
#
# FORMAT: "config_key|script_path|required_args"
#   - config_key:    The key name in config.ini (e.g., "ec2")
#   - script_path:   Path to the report script
#   - required_args: Space-separated list of CLI flags the script needs
#                    (empty string if no args needed)
#
# To add a new report:
#   1. Add an entry to REPORT_DEFINITIONS below
#   2. Add the config key to config.ini
#   3. Place the script in the appropriate ./script/<category>/ directory

REPORT_DEFINITIONS=(
    "acm|./script/inventory/acm_report.sh|-r"
    "asg|./script/inventory/asg_report.sh|-r"
    "backup|./script/inventory/backup_report.sh|-r"
    "billing|./script/inventory/aws_billing_report.sh|-b -e"
    "cloudfront|./script/inventory/cloudfront_report.sh|"
    "cloudwatch|./script/inventory/cloudwatch_report.sh|-r"
    "data_transfer|./script/inventory/data_transfer_report.sh|-r -b -e"
    "directconnect|./script/inventory/directconnect_report.sh|-r"
    "dynamodb|./script/inventory/dynamodb_report.sh|-r"
    "ebs_detailed|./script/inventory/ebs_report.sh|-r"
    "ebs_utilization|./script/inventory/ebs_utilization_report.sh|-r -b -e"
    "ec2|./script/inventory/aws_ec2_report.sh|-r -b -e -s"
    "ecr|./script/inventory/ecr_report.sh|-r"
    "ecs|./script/inventory/ecs_report.sh|-r"
    "efs|./script/inventory/efs_report.sh|-r"
    "eks|./script/inventory/eks_report.sh|-r"
    "elasticache|./script/inventory/elasticache_report.sh|-r"
    "elb|./script/inventory/elb_report.sh|-r"
    "glue|./script/inventory/glue_report.sh|-r"
    "iam|./script/inventory/iam_report.sh|"
    "kms|./script/inventory/kms_report.sh|-r"
    "lambda|./script/inventory/lambda_report.sh|-r"
    "rds|./script/inventory/aws_rds_report.sh|-r -b -e"
    "ri|./script/inventory/aws_ri_report.sh|-r"
    "route53|./script/inventory/route53_report.sh|"
    "s3|./script/inventory/s3_report.sh|"
    "secrets_manager|./script/inventory/secrets_manager_report.sh|-r"
    "ses|./script/inventory/ses_report.sh|-r"
    "sns|./script/inventory/sns_report.sh|-r"
    "sp|./script/inventory/aws_sp_report.sh|"
    "vpc|./script/inventory/vpc_report.sh|-r"
    "vpn|./script/inventory/vpn_report.sh|-r"
    "waf|./script/inventory/waf_report.sh|-r -b -e"
    "workspaces|./script/inventory/aws_workspaces_report.sh|-r"
    "sqs|./script/inventory/sqs_report.sh|-r"
    "apigateway|./script/inventory/apigateway_report.sh|-r"
    "stepfunctions|./script/inventory/stepfunctions_report.sh|-r"
    "natgateway|./script/inventory/natgateway_report.sh|-r"
    "transitgateway|./script/inventory/transitgateway_report.sh|-r"
    "kinesis|./script/inventory/kinesis_report.sh|-r"
    "redshift|./script/inventory/redshift_report.sh|-r"
    "opensearch|./script/inventory/opensearch_report.sh|-r"
    "codepipeline|./script/inventory/codepipeline_report.sh|-r"
    "ssm_params|./script/inventory/ssm_params_report.sh|-r"
    "eventbridge|./script/inventory/eventbridge_report.sh|-r"
    "config|./script/inventory/config_report.sh|-r"
    "sagemaker|./script/inventory/sagemaker_report.sh|-r"
    "bedrock|./script/inventory/bedrock_report.sh|-r"
    "lightsail|./script/inventory/lightsail_report.sh|-r"
    "documentdb|./script/inventory/documentdb_report.sh|-r"
    "msk|./script/inventory/msk_report.sh|-r"
    "cognito|./script/inventory/cognito_report.sh|-r"
    "apprunner|./script/inventory/apprunner_report.sh|-r"
    "mq|./script/inventory/mq_report.sh|-r"
    "neptune|./script/inventory/neptune_report.sh|-r"
    "grafana|./script/inventory/grafana_report.sh|-r"
    "transfer_family|./script/inventory/transfer_family_report.sh|-r"
    "tagging_compliance|./script/compliance/tagging_compliance_report.sh|-r"
    "resource_lifecycle|./script/compliance/resource_lifecycle_report.sh|-r"
    # --- Price Optimization Reports ---
    "opt_ec2_rightsizing|./script/optimization/ec2_rightsizing_report.sh|-r -b -e"
    "opt_rds_rightsizing|./script/optimization/rds_rightsizing_report.sh|-r -b -e"
    "opt_idle_resources|./script/optimization/idle_resources_report.sh|-r -b -e"
    "opt_ebs_optimization|./script/optimization/ebs_optimization_report.sh|-r -b -e"
    "opt_ri_sp_advisor|./script/optimization/ri_sp_advisor_report.sh|-r -b -e"
    "opt_data_transfer|./script/optimization/data_transfer_optimization_report.sh|-r -b -e"
    "opt_s3_storage|./script/optimization/s3_storage_optimization_report.sh|-r -b -e"
    "opt_efs_storage|./script/optimization/efs_storage_optimization_report.sh|-r -b -e"
    "opt_trusted_advisor|./script/optimization/trusted_advisor_report.sh|-r -b -e"
    "opt_summary|./script/optimization/optimization_summary_report.sh|-r -b -e"
    "opt_cost_trend|./script/optimization/cost_trend_report.sh|-b -e"
    # --- Security Audit Reports ---
    "sec_trusted_advisor|./script/security/sec_trusted_advisor.sh|"
    "sec_iam_audit|./script/security/sec_iam_audit.sh|"
    "sec_sg_audit|./script/security/sec_sg_audit.sh|-r"
    "sec_s3_audit|./script/security/sec_s3_audit.sh|"
    "sec_encryption_audit|./script/security/sec_encryption_audit.sh|-r"
    "sec_network_audit|./script/security/sec_network_audit.sh|-r"
    "sec_logging_audit|./script/security/sec_logging_audit.sh|-r"
    "sec_securityhub|./script/security/sec_securityhub.sh|-r"
    "sec_summary|./script/security/sec_summary_report.sh|"
    # --- Compliance & Governance Reports ---
    "delta_report|./script/compliance/delta_report.sh|"
    # --- Compliance Scorecard (must be LAST) ---
    "scorecard|./script/compliance/scorecard_report.sh|"
)

# Build the TASKS array based on config values and CLI arguments.
# Requires: PASS_THROUGH_ARGS array to be set.
# Optional: RUN_MODE variable (comma-separated: inventory, optimize, security, all). Default: all
build_task_list() {
    TASKS=()
    local mode="${RUN_MODE:-all}"

    for definition in "${REPORT_DEFINITIONS[@]}"; do
        IFS='|' read -r config_key script_path needed_args <<< "$definition"

        # Filter by mode (supports comma-separated modes like "optimize,security")
        if [[ "$mode" != "all" ]]; then
            local include=false

            # Check each mode in the comma-separated list
            IFS=',' read -r -a modes <<< "$mode"
            for m in "${modes[@]}"; do
                case "$m" in
                    inventory)
                        if [[ "$config_key" != opt_* && "$config_key" != sec_* ]]; then
                            include=true
                        fi
                        ;;
                    optimize)
                        if [[ "$config_key" == opt_* ]]; then
                            include=true
                        fi
                        ;;
                    security)
                        if [[ "$config_key" == sec_* ]]; then
                            include=true
                        fi
                        ;;
                esac
            done

            if [[ "$include" == "false" ]]; then
                continue
            fi
        fi

        # Check if this report is enabled in config
        # Use indirect variable reference to get the config value
        # Strip any whitespace/carriage returns for robustness
        local raw_value="${!config_key:-0}"
        local config_value
        config_value=$(echo "$raw_value" | tr -d '[:space:]')

        if [[ "$config_value" == "1" ]]; then
            local run_args=""
            if [[ -n "$needed_args" ]]; then
                # Check for per-service region override from .service_regions file
                local service_regions_file="${OUTPUT_DIR:-}/.service_regions"
                local has_region_flag=false
                echo "$needed_args" | grep -q "\-r" && has_region_flag=true || true
                if [[ -f "$service_regions_file" ]] && [[ "$has_region_flag" == "true" ]]; then
                    # Look up this config key's specific regions
                    local key_regions
                    key_regions=$(grep "^${config_key}=" "$service_regions_file" 2>/dev/null | cut -d'=' -f2 || true)
                    if [[ -n "$key_regions" ]]; then
                        # Override -r in PASS_THROUGH_ARGS with per-service regions
                        local TEMP_PASS_THROUGH=()
                        local skip_next=false
                        for (( i=0; i<${#PASS_THROUGH_ARGS[@]}; i++ )); do
                            if [[ "$skip_next" == "true" ]]; then
                                skip_next=false
                                continue
                            fi
                            if [[ "${PASS_THROUGH_ARGS[$i]}" == "-r" ]]; then
                                skip_next=true  # Skip the -r value
                                continue
                            fi
                            TEMP_PASS_THROUGH+=("${PASS_THROUGH_ARGS[$i]}")
                        done
                        # Add per-service regions
                        TEMP_PASS_THROUGH+=("-r" "$key_regions")
                        # Build args from temp array
                        local OLD_PASS_THROUGH=("${PASS_THROUGH_ARGS[@]}")
                        PASS_THROUGH_ARGS=("${TEMP_PASS_THROUGH[@]}")
                        run_args=$(get_report_args "$script_path" "$needed_args")
                        PASS_THROUGH_ARGS=("${OLD_PASS_THROUGH[@]}")
                    else
                        run_args=$(get_report_args "$script_path" "$needed_args")
                    fi
                else
                    run_args=$(get_report_args "$script_path" "$needed_args")
                fi
            fi
            TASKS+=("${script_path}|${run_args}")
        fi
    done
}

# Set execute permissions for all registered scripts
set_script_permissions() {
    for definition in "${REPORT_DEFINITIONS[@]}"; do
        IFS='|' read -r _ script_path _ <<< "$definition"
        if [[ -f "$script_path" ]]; then
            chmod +x "$script_path"
        fi
    done
    chmod +x ./lib/python/combine_csv.py 2>/dev/null || true
}

# Validate that all registered scripts exist
validate_scripts() {
    local missing=0
    for definition in "${REPORT_DEFINITIONS[@]}"; do
        IFS='|' read -r _ script_path _ <<< "$definition"
        if [[ ! -f "$script_path" ]]; then
            log_error "Required script not found: $script_path"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        log_error "Please ensure all scripts are in the correct directory."
        exit 1
    fi
}

# Helper: extract relevant CLI args from PASS_THROUGH_ARGS
get_report_args() {
    local script_path="$1"
    shift
    local needed_args="$*"
    local run_args=()

    for arg in $needed_args; do
        for (( i=0; i<${#PASS_THROUGH_ARGS[@]}; i++ )); do
            if [[ "${PASS_THROUGH_ARGS[$i]}" == "$arg" ]]; then
                run_args+=("${PASS_THROUGH_ARGS[$i]}")
                if [[ "$arg" != "-s" ]]; then
                    run_args+=("${PASS_THROUGH_ARGS[$i+1]}")
                fi
            fi
        done
    done
    echo "${run_args[@]}"
}

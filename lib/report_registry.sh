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
#   3. Place the script in ./script/

REPORT_DEFINITIONS=(
    "acm|./script/acm_report.sh|-r"
    "asg|./script/asg_report.sh|-r"
    "backup|./script/backup_report.sh|-r"
    "billing|./script/aws_billing_report.sh|-b -e"
    "cloudfront|./script/cloudfront_report.sh|"
    "cloudwatch|./script/cloudwatch_report.sh|-r"
    "data_transfer|./script/data_transfer_report.sh|-r -b -e"
    "directconnect|./script/directconnect_report.sh|-r"
    "dynamodb|./script/dynamodb_report.sh|-r"
    "ebs_detailed|./script/ebs_report.sh|-r"
    "ebs_utilization|./script/ebs_utilization_report.sh|-r -b -e"
    "ec2|./script/aws_ec2_report.sh|-r -b -e -s"
    "ecr|./script/ecr_report.sh|-r"
    "ecs|./script/ecs_report.sh|-r"
    "efs|./script/efs_report.sh|-r"
    "eks|./script/eks_report.sh|-r"
    "elasticache|./script/elasticache_report.sh|-r"
    "elb|./script/elb_report.sh|-r"
    "glue|./script/glue_report.sh|-r"
    "iam|./script/iam_report.sh|"
    "kms|./script/kms_report.sh|-r"
    "lambda|./script/lambda_report.sh|-r"
    "rds|./script/aws_rds_report.sh|-r -b -e"
    "ri|./script/aws_ri_report.sh|-r"
    "route53|./script/route53_report.sh|"
    "s3|./script/s3_report.sh|"
    "secrets_manager|./script/secrets_manager_report.sh|-r"
    "ses|./script/ses_report.sh|-r"
    "sns|./script/sns_report.sh|-r"
    "sp|./script/aws_sp_report.sh|"
    "vpc|./script/vpc_report.sh|-r"
    "vpn|./script/vpn_report.sh|-r"
    "waf|./script/waf_report.sh|-r -b -e"
    "workspaces|./script/aws_workspaces_report.sh|-r"
    "sqs|./script/sqs_report.sh|-r"
    "apigateway|./script/apigateway_report.sh|-r"
    "stepfunctions|./script/stepfunctions_report.sh|-r"
    "natgateway|./script/natgateway_report.sh|-r"
    "transitgateway|./script/transitgateway_report.sh|-r"
    "kinesis|./script/kinesis_report.sh|-r"
    "redshift|./script/redshift_report.sh|-r"
    "opensearch|./script/opensearch_report.sh|-r"
    "codepipeline|./script/codepipeline_report.sh|-r"
    "ssm_params|./script/ssm_params_report.sh|-r"
    "eventbridge|./script/eventbridge_report.sh|-r"
    "config|./script/config_report.sh|-r"
    "sagemaker|./script/sagemaker_report.sh|-r"
    "bedrock|./script/bedrock_report.sh|-r"
    "lightsail|./script/lightsail_report.sh|-r"
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
                run_args=$(get_report_args "$script_path" "$needed_args")
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
    chmod +x ./combine_csv.py 2>/dev/null || true
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

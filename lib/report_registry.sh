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
    "iam|./script/iam_report.sh|"
    "kms|./script/kms_report.sh|-r"
    "lambda|./script/lambda_report.sh|-r"
    "rds|./script/aws_rds_report.sh|-r -b -e"
    "ri|./script/aws_ri_report.sh|-r"
    "route53|./script/route53_report.sh|"
    "s3|./script/s3_report.sh|"
    "secrets_manager|./script/secrets_manager_report.sh|-r"
    "sp|./script/aws_sp_report.sh|"
    "vpc|./script/vpc_report.sh|-r"
    "vpn|./script/vpn_report.sh|-r"
    "waf|./script/waf_report.sh|-r -b -e"
    "workspaces|./script/aws_workspaces_report.sh|-r"
)

# Build the TASKS array based on config values and CLI arguments.
# Requires: PASS_THROUGH_ARGS array to be set.
build_task_list() {
    TASKS=()

    for definition in "${REPORT_DEFINITIONS[@]}"; do
        IFS='|' read -r config_key script_path needed_args <<< "$definition"

        # Check if this report is enabled in config
        # Use indirect variable reference to get the config value
        local config_value="${!config_key:-0}"

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

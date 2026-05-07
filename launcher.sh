#!/bin/bash
# launcher.sh
# Interactive TUI launcher for AWS Cloud Utility Scripts.
# Uses whiptail for terminal-based GUI with checkboxes, radio buttons, and input fields.
#
# Usage:
#   ./launcher.sh          # Launch interactive TUI
#   ./launcher.sh --help   # Show help
#
# Prerequisites:
#   - whiptail (pre-installed on most Linux distros and AWS CloudShell)
#   - All other dependencies handled by main_report_runner.sh
#
# This script generates the appropriate CLI command and executes main_report_runner.sh.

set -euo pipefail

# --- Configuration ---
TITLE="AWS Cloud Utility Scripts"
BACKTITLE="AWS Cloud Utility Scripts v2.0"

# --- Check whiptail availability ---
if ! command -v whiptail &>/dev/null; then
    echo "❌ whiptail is not installed."
    echo ""
    echo "Install it with:"
    echo "  Ubuntu/Debian: sudo apt-get install whiptail"
    echo "  CentOS/RHEL:   sudo yum install newt"
    echo "  Alpine:        sudo apk add newt"
    echo ""
    echo "Or use the CLI directly:"
    echo "  ./main_report_runner.sh -b <start> -e <end> [-m mode] [-r regions]"
    exit 1
fi

# --- Helper Functions ---

show_welcome() {
    whiptail --title "$TITLE" --msgbox \
"Welcome to AWS Cloud Utility Scripts!

This interactive launcher will guide you through:
1. Selecting run mode (Inventory/Optimize/Security)
2. Choosing specific reports to enable
3. Setting date range and regions
4. Configuring optional features

Press OK to continue." 16 60
}

select_mode() {
    MODE=$(whiptail --title "$TITLE - Run Mode" --radiolist \
"Select the run mode:

Use SPACE to select, ENTER to confirm." 15 60 5 \
        "all" "Run all enabled reports" ON \
        "inventory" "Inventory reports only" OFF \
        "optimize" "Cost optimization only" OFF \
        "security" "Security audit only" OFF \
        "optimize,security" "Optimization + Security" OFF \
        3>&1 1>&2 2>&3) || exit 0
}

select_inventory_reports() {
    INVENTORY_SELECTION=$(whiptail --title "$TITLE - Inventory Reports" --checklist \
"Select inventory reports to enable:

Use SPACE to toggle, ENTER to confirm." 30 70 20 \
        "ec2" "EC2 Instances" ON \
        "rds" "RDS Databases" ON \
        "s3" "S3 Buckets" ON \
        "lambda" "Lambda Functions" OFF \
        "ebs_detailed" "EBS Volumes" ON \
        "ebs_utilization" "EBS Utilization Metrics" OFF \
        "iam" "IAM Users" ON \
        "vpc" "VPC Resources" ON \
        "elb" "Load Balancers" OFF \
        "ecs" "ECS Clusters" OFF \
        "eks" "EKS Clusters" OFF \
        "cloudwatch" "CloudWatch Alarms & Logs" OFF \
        "billing" "Billing & Cost" ON \
        "cloudfront" "CloudFront CDN" OFF \
        "dynamodb" "DynamoDB Tables" OFF \
        "elasticache" "ElastiCache" OFF \
        "route53" "Route 53 DNS" OFF \
        "sns" "SNS Topics" OFF \
        "sqs" "SQS Queues" OFF \
        "glue" "Glue ETL Jobs" OFF \
        "kms" "KMS Keys" OFF \
        "secrets_manager" "Secrets Manager" OFF \
        "acm" "ACM Certificates" OFF \
        "backup" "AWS Backup" OFF \
        "waf" "WAF Rules" OFF \
        "sagemaker" "SageMaker" OFF \
        "bedrock" "Bedrock AI" OFF \
        "lightsail" "Lightsail" OFF \
        "tagging_compliance" "Tagging Compliance" OFF \
        "resource_lifecycle" "Resource Lifecycle" OFF \
        "delta_report" "Delta Report (vs baseline)" OFF \
        "scorecard" "Executive Scorecard" OFF \
        3>&1 1>&2 2>&3) || INVENTORY_SELECTION=""
}

select_optimization_reports() {
    OPT_SELECTION=$(whiptail --title "$TITLE - Optimization Reports" --checklist \
"Select optimization reports to enable:

Use SPACE to toggle, ENTER to confirm." 22 70 12 \
        "opt_ec2_rightsizing" "EC2 Right-Sizing" ON \
        "opt_rds_rightsizing" "RDS Right-Sizing" ON \
        "opt_idle_resources" "Idle Resource Detection" ON \
        "opt_ebs_optimization" "EBS Volume Optimization" ON \
        "opt_ri_sp_advisor" "RI/Savings Plans Advisor" OFF \
        "opt_data_transfer" "Data Transfer Costs" OFF \
        "opt_s3_storage" "S3 Storage Optimization" ON \
        "opt_efs_storage" "EFS Storage Optimization" OFF \
        "opt_cost_trend" "Cost Trend Analysis" OFF \
        "opt_trusted_advisor" "Trusted Advisor (Cost)" OFF \
        "opt_summary" "Optimization Summary" ON \
        3>&1 1>&2 2>&3) || OPT_SELECTION=""
}

select_security_reports() {
    SEC_SELECTION=$(whiptail --title "$TITLE - Security Reports" --checklist \
"Select security reports to enable:

Use SPACE to toggle, ENTER to confirm." 20 70 10 \
        "sec_trusted_advisor" "Trusted Advisor Security" ON \
        "sec_iam_audit" "IAM Audit" ON \
        "sec_sg_audit" "Security Groups" ON \
        "sec_s3_audit" "S3 Bucket Security" ON \
        "sec_encryption_audit" "Encryption Audit" ON \
        "sec_network_audit" "Network Security" ON \
        "sec_logging_audit" "Logging & Monitoring" ON \
        "sec_securityhub" "Security Hub Findings" OFF \
        "sec_summary" "Security Summary" ON \
        3>&1 1>&2 2>&3) || SEC_SELECTION=""
}

input_date_range() {
    # Default: last 30 days
    DEFAULT_END=$(date +%Y-%m-%d)
    DEFAULT_START=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "2025-01-01")

    START_DATE=$(whiptail --title "$TITLE - Date Range" --inputbox \
"Enter START date (YYYY-MM-DD):

This is used for CloudWatch metrics and Cost Explorer queries." 12 60 "$DEFAULT_START" \
        3>&1 1>&2 2>&3) || exit 0

    END_DATE=$(whiptail --title "$TITLE - Date Range" --inputbox \
"Enter END date (YYYY-MM-DD):" 10 60 "$DEFAULT_END" \
        3>&1 1>&2 2>&3) || exit 0

    # Validate date format
    if ! date -d "$START_DATE" &>/dev/null 2>&1; then
        whiptail --title "Error" --msgbox "Invalid start date: $START_DATE\nPlease use YYYY-MM-DD format." 10 50
        input_date_range
    fi
    if ! date -d "$END_DATE" &>/dev/null 2>&1; then
        whiptail --title "Error" --msgbox "Invalid end date: $END_DATE\nPlease use YYYY-MM-DD format." 10 50
        input_date_range
    fi
}

input_regions() {
    REGIONS=$(whiptail --title "$TITLE - Regions" --inputbox \
"Enter AWS regions (comma-separated):

Common regions:
  ap-southeast-1 (Singapore)
  ap-southeast-3 (Jakarta)
  us-east-1 (N. Virginia)
  eu-west-1 (Ireland)" 16 60 "ap-southeast-1,ap-southeast-3" \
        3>&1 1>&2 2>&3) || REGIONS="ap-southeast-1,ap-southeast-3"
}

select_parallel() {
    PARALLEL=$(whiptail --title "$TITLE - Execution Mode" --radiolist \
"Select execution mode:" 12 60 3 \
        "1" "Parallel (faster, recommended)" ON \
        "0" "Sequential (safer for large accounts)" OFF \
        3>&1 1>&2 2>&3) || PARALLEL="1"
}

select_report_method() {
    REPORT_METHOD=$(whiptail --title "$TITLE - Report Selection" --radiolist \
"How do you want to select reports?

Auto-discover uses your billing data to detect which
AWS services are active and enables only those reports." 14 65 3 \
        "auto" "Auto-discover from billing (recommended)" ON \
        "manual" "Manual selection from checklist" OFF \
        "config" "Use config.ini as-is" OFF \
        3>&1 1>&2 2>&3) || REPORT_METHOD="config"
}

confirm_and_run() {
    # Build the command
    if [[ "$REPORT_METHOD" == "auto" ]]; then
        # Auto-discover: don't pass -r (regions will be auto-detected)
        CMD="./main_report_runner.sh -b $START_DATE -e $END_DATE -m $MODE"
    else
        CMD="./main_report_runner.sh -b $START_DATE -e $END_DATE -r $REGIONS -m $MODE"
    fi

    # Add auto-discover flag if selected
    if [[ -n "${AUTO_DISCOVER_FLAG:-}" ]]; then
        CMD="$CMD $AUTO_DISCOVER_FLAG"
    fi

    # Build config overrides summary
    local report_summary=""
    if [[ "${REPORT_METHOD:-}" == "auto" ]]; then
        report_summary="Reports: Auto-discover from billing data\n"
    elif [[ "${REPORT_METHOD:-}" == "config" ]]; then
        report_summary="Reports: Using config.ini as-is\n"
    else
        if [[ -n "${INVENTORY_SELECTION:-}" ]]; then
            report_summary="Inventory: $(echo $INVENTORY_SELECTION | tr -d '"' | wc -w) reports\n"
        fi
        if [[ -n "${OPT_SELECTION:-}" ]]; then
            report_summary="${report_summary}Optimization: $(echo $OPT_SELECTION | tr -d '"' | wc -w) reports\n"
        fi
        if [[ -n "${SEC_SELECTION:-}" ]]; then
            report_summary="${report_summary}Security: $(echo $SEC_SELECTION | tr -d '"' | wc -w) reports\n"
        fi
    fi

    if whiptail --title "$TITLE - Confirm" --yesno \
"Ready to run with these settings:

Mode:       $MODE
Start Date: $START_DATE
End Date:   $END_DATE
Regions:    $REGIONS
Parallel:   $( [[ "$PARALLEL" == "1" ]] && echo "Yes" || echo "No" )

${report_summary}
Command: $CMD

Proceed?" 20 70; then
        # Write temporary config with selected reports
        write_temp_config
        echo ""
        echo "🚀 Launching report generation..."
        echo "   Command: $CMD"
        echo ""
        exec $CMD
    else
        whiptail --title "$TITLE" --msgbox "Cancelled. No reports were run." 8 50
        exit 0
    fi
}

write_temp_config() {
    # Update config.ini with selected reports
    # First, set all to 0, then enable selected ones

    local config_file="config.ini"
    local temp_file=$(mktemp)

    # Copy original config
    cp "$config_file" "$temp_file"

    # Function to set a key in config
    set_config_key() {
        local key="$1"
        local value="$2"
        if grep -q "^${key}=" "$config_file"; then
            sed -i "s/^${key}=.*/${key}=${value}/" "$config_file"
        fi
    }

    # Set parallel mode
    set_config_key "parallel" "$PARALLEL"

    # Enable selected inventory reports
    if [[ -n "${INVENTORY_SELECTION:-}" ]]; then
        for key in $(echo "$INVENTORY_SELECTION" | tr -d '"'); do
            set_config_key "$key" "1"
        done
    fi

    # Enable selected optimization reports
    if [[ -n "${OPT_SELECTION:-}" ]]; then
        for key in $(echo "$OPT_SELECTION" | tr -d '"'); do
            set_config_key "$key" "1"
        done
    fi

    # Enable selected security reports
    if [[ -n "${SEC_SELECTION:-}" ]]; then
        for key in $(echo "$SEC_SELECTION" | tr -d '"'); do
            set_config_key "$key" "1"
        done
    fi
}

# =============================================================================
# Main Flow
# =============================================================================

# Handle --help flag
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "AWS Cloud Utility Scripts - Interactive Launcher"
    echo ""
    echo "Usage:"
    echo "  ./launcher.sh          Launch interactive TUI (requires whiptail)"
    echo "  ./launcher.sh --help   Show this help"
    echo ""
    echo "For CLI usage without TUI:"
    echo "  ./main_report_runner.sh -b <start> -e <end> [-m mode] [-r regions]"
    echo ""
    echo "Prerequisites:"
    echo "  - whiptail (pre-installed on most Linux and AWS CloudShell)"
    echo "  - AWS CLI v2 configured with appropriate credentials"
    exit 0
fi

# Run the interactive flow
show_welcome
select_mode
input_date_range
select_parallel
select_report_method

# Region selection: auto-discover skips manual region input
if [[ "$REPORT_METHOD" == "auto" ]]; then
    # Auto-discover mode: regions will be auto-detected from billing
    AUTO_DISCOVER_FLAG="-a"
    REGIONS="auto-detected"
    whiptail --title "$TITLE - Regions" --msgbox \
"Regions will be auto-detected from billing data.

If you want to override, use CLI directly:
  ./main_report_runner.sh -b $START_DATE -e $END_DATE -a -r us-east-1,eu-west-1" 12 65
else
    # Manual mode: ask for regions
    input_regions
    AUTO_DISCOVER_FLAG=""
fi

# Show report selection based on mode and method
if [[ "$REPORT_METHOD" == "auto" ]]; then
    : # Already set AUTO_DISCOVER_FLAG above
elif [[ "$REPORT_METHOD" == "manual" ]]; then
    AUTO_DISCOVER_FLAG=""
    case "$MODE" in
        all)
            select_inventory_reports
            select_optimization_reports
            select_security_reports
            ;;
        inventory)
            select_inventory_reports
            ;;
        optimize)
            select_optimization_reports
            ;;
        security)
            select_security_reports
            ;;
        optimize,security)
            select_optimization_reports
            select_security_reports
            ;;
    esac
else
    # config mode: use config.ini as-is
    AUTO_DISCOVER_FLAG=""
fi

confirm_and_run

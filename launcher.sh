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

# --- Ensure scripts are executable ---
chmod +x main_report_runner.sh 2>/dev/null || true
chmod +x multi_account_runner.sh 2>/dev/null || true

# --- Helper Functions ---

show_welcome() {
    whiptail --title "$TITLE" --msgbox \
"Welcome to AWS Cloud Utility Scripts!

This launcher will guide you through:

  1. Select run mode (Inventory / Optimize / Security / Discovery)
  2. Choose reports to enable
  3. Set date range and regions
  4. Configure execution options

Press OK to continue." 18 65
}

select_mode() {
    MODE=$(whiptail --title "$TITLE - Run Mode" --radiolist \
"Select run mode (SPACE to select, ENTER to confirm):" 18 65 7 \
        "all" "Run all modes (Inventory + Optimize + Security)" ON \
        "inventory" "Inventory reports only" OFF \
        "optimize" "Cost optimization only" OFF \
        "security" "Security audit only" OFF \
        "usage" "Usage reports (Bedrock tokens, QuickSight)" OFF \
        "optimize,security" "Optimization + Security" OFF \
        "discovery" "Architecture Discovery (Mermaid diagrams)" OFF \
        3>&1 1>&2 2>&3) || exit 0
}

select_inventory_reports() {
    INVENTORY_SELECTION=$(whiptail --title "$TITLE - Inventory Reports" --checklist \
"Select inventory reports (SPACE to toggle, ENTER to confirm):" 35 75 25 \
        "ec2" "EC2 Instances + CPU/Memory metrics" ON \
        "rds" "RDS Databases + utilization" ON \
        "s3" "S3 Buckets (size, objects)" ON \
        "lambda" "Lambda Functions" OFF \
        "ebs_detailed" "EBS Volumes (type, IOPS)" ON \
        "ebs_utilization" "EBS Utilization (read/write)" OFF \
        "iam" "IAM Users" ON \
        "vpc" "VPC Resources (subnets, SG, EIP)" ON \
        "elb" "Load Balancers (ALB/NLB)" OFF \
        "ecs" "ECS Clusters" OFF \
        "eks" "EKS Kubernetes Clusters" OFF \
        "cloudwatch" "CloudWatch Alarms + Log Groups" OFF \
        "billing" "Billing & Cost per Service" ON \
        "cloudfront" "CloudFront Distributions" OFF \
        "dynamodb" "DynamoDB Tables" OFF \
        "elasticache" "ElastiCache Clusters" OFF \
        "route53" "Route 53 Hosted Zones" OFF \
        "sns" "SNS Topics" OFF \
        "sqs" "SQS Queues" OFF \
        "glue" "Glue Jobs/Crawlers/Databases" OFF \
        "kms" "KMS Encryption Keys" OFF \
        "secrets_manager" "Secrets Manager" OFF \
        "acm" "ACM Certificates" OFF \
        "backup" "AWS Backup Vaults/Plans" OFF \
        "waf" "WAF Web ACLs" OFF \
        "sagemaker" "SageMaker Endpoints" OFF \
        "bedrock" "Bedrock Models" OFF \
        "lightsail" "Lightsail Instances" OFF \
        3>&1 1>&2 2>&3) || INVENTORY_SELECTION=""
}

select_compliance_reports() {
    COMPLIANCE_SELECTION=$(whiptail --title "$TITLE - Compliance & Governance" --checklist \
"Select compliance reports (SPACE to toggle, ENTER to confirm):

Note: These analyze data from other reports." 16 75 4 \
        "tagging_compliance" "Tagging Compliance (mandatory tags check)" OFF \
        "resource_lifecycle" "Resource Lifecycle (stale AMIs, old runtimes)" OFF \
        "delta_report" "Delta Report (compare vs previous run)" OFF \
        "scorecard" "Executive Scorecard (Health Score 0-100)" OFF \
        3>&1 1>&2 2>&3) || COMPLIANCE_SELECTION=""
}

select_discovery_scripts() {
    DISCOVERY_SELECTION=$(whiptail --title "$TITLE - Architecture Discovery" --checklist \
"Select architecture diagrams to generate (SPACE to toggle):

Discovers resource relationships and outputs Mermaid diagrams." 16 78 3 \
        "vpc" "VPC Topology (EC2, RDS, ELB, NAT, Subnets)" ON \
        "serverless" "Serverless (Lambda, API GW, SQS, SNS, DynamoDB)" ON \
        "edge" "Edge/CDN (Route 53 -> CloudFront -> Origins)" ON \
        3>&1 1>&2 2>&3) || DISCOVERY_SELECTION=""
}

run_discovery() {
    # Execute discovery scripts directly (not through main_report_runner.sh)
    local region_flag=""
    if [[ "$REGIONS" != "auto-detected" && -n "$REGIONS" ]]; then
        region_flag="-r $REGIONS"
    fi

    # Setup output dir
    local YEAR=$(date +"%Y")
    local MONTH=$(date +"%m")
    local DAY=$(date +"%d")
    export OUTPUT_DIR="export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}"
    mkdir -p "$OUTPUT_DIR"

    chmod +x script/discovery/*.sh 2>/dev/null || true

    echo ""
    echo "🔍 Running Architecture Discovery..."
    echo "   Output: $OUTPUT_DIR/"
    echo ""

    for selection in $(echo "$DISCOVERY_SELECTION" | tr -d '"'); do
        case "$selection" in
            vpc)
                echo "📐 Discovering VPC topology..."
                ./script/discovery/vpc_topology.sh $region_flag
                ;;
            serverless)
                echo "⚡ Discovering serverless topology..."
                ./script/discovery/serverless_topology.sh $region_flag
                ;;
            edge)
                echo "☁️  Discovering edge/CDN topology..."
                ./script/discovery/edge_topology.sh
                ;;
        esac
    done

    echo ""
    echo "✅ Architecture discovery complete!"
    echo "   Diagrams saved to: $OUTPUT_DIR/"
    echo ""
    echo "   Files generated:"
    ls -1 "$OUTPUT_DIR"/architecture_*.md 2>/dev/null | while read -r f; do
        echo "     • $(basename "$f")"
    done
    echo ""
    echo "   View in GitHub, VS Code (Mermaid extension), or paste into mermaid.live"
}

run_usage() {
    # Execute usage report scripts directly with chart generation support
    local region_flag=""

    # Setup output dir
    local YEAR=$(date +"%Y")
    local MONTH=$(date +"%m")
    local DAY=$(date +"%d")
    export OUTPUT_DIR="export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}"
    mkdir -p "$OUTPUT_DIR"

    # --- Install Prerequisites ---
    echo ""
    echo "🔧 Checking prerequisites..."

    # Check and install system dependencies (jq, bc)
    local missing_deps=()
    command -v jq &>/dev/null || missing_deps+=("jq")
    command -v bc &>/dev/null || missing_deps+=("bc")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "   Installing system dependencies: ${missing_deps[*]}..."
        if command -v yum &>/dev/null; then
            sudo yum install -y "${missing_deps[@]}" >/dev/null 2>&1
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y "${missing_deps[@]}" >/dev/null 2>&1
        elif command -v apk &>/dev/null; then
            sudo apk add "${missing_deps[@]}" >/dev/null 2>&1
        else
            echo "   ⚠️  Cannot auto-install ${missing_deps[*]}. Please install manually."
        fi
    fi

    # Check Python dependencies if charts are requested
    if [[ "${GENERATE_USAGE_CHARTS:-false}" == "true" ]]; then
        if ! command -v python3 &>/dev/null; then
            echo "   ⚠️  python3 not found. Installing..."
            if command -v yum &>/dev/null; then
                sudo yum install -y python3 python3-pip >/dev/null 2>&1
            elif command -v apt-get &>/dev/null; then
                sudo apt-get install -y python3 python3-pip >/dev/null 2>&1
            else
                echo "   ❌ Cannot auto-install python3. Please install manually."
                echo "      Charts will be skipped."
                GENERATE_USAGE_CHARTS=false
            fi
        fi

        if [[ "${GENERATE_USAGE_CHARTS:-false}" == "true" ]]; then
            # Check and install Python packages
            local py_missing=false
            python3 -c "import matplotlib, pandas, openpyxl" 2>/dev/null || py_missing=true

            if [[ "$py_missing" == "true" ]]; then
                echo "   Installing Python packages (matplotlib, pandas, openpyxl)..."
                if pip3 install matplotlib pandas openpyxl >/dev/null 2>&1; then
                    echo "   ✅ Python packages installed."
                elif sudo pip3 install matplotlib pandas openpyxl >/dev/null 2>&1; then
                    echo "   ✅ Python packages installed (with sudo)."
                elif pip3 install --user matplotlib pandas openpyxl >/dev/null 2>&1; then
                    echo "   ✅ Python packages installed (user mode)."
                else
                    echo "   ❌ Failed to install Python packages."
                    echo "      Run manually: pip3 install matplotlib pandas openpyxl"
                    echo "      Charts will be skipped."
                    GENERATE_USAGE_CHARTS=false
                fi
            else
                echo "   ✅ Python packages already installed."
            fi
        fi
    fi

    echo "   ✅ Prerequisites check complete."

    # --- Auto-discover regions if requested ---
    if [[ "$REGIONS" == "auto-detected" ]]; then
        echo ""
        echo "🌍 Auto-detecting regions from billing data..."
        source ./lib/auto_discover.sh

        # Use logger stubs if not defined
        type log_start &>/dev/null 2>&1 || log_start() { echo "  $*"; }
        type log_success &>/dev/null 2>&1 || log_success() { echo "  ✅ $*"; }
        type log_error &>/dev/null 2>&1 || log_error() { echo "  ❌ $*"; }

        if auto_discover_regions "$START_DATE" "$END_DATE"; then
            region_flag="-r $DISCOVERED_REGIONS"
            echo "   Detected regions: $DISCOVERED_REGIONS"
        else
            # Fallback to default regions
            echo "   ⚠️  Could not auto-detect. Using default: ap-southeast-1,us-east-1"
            region_flag="-r ap-southeast-1,us-east-1"
        fi
    elif [[ -n "$REGIONS" ]]; then
        region_flag="-r $REGIONS"
    fi

    local chart_flag=""
    if [[ "${GENERATE_USAGE_CHARTS:-false}" == "true" ]]; then
        chart_flag="-g"
    fi

    chmod +x script/usage/*.sh 2>/dev/null || true

    echo ""
    echo "📊 Running Usage Reports..."
    echo "   Output: $OUTPUT_DIR/"
    echo "   Period: $START_DATE to $END_DATE"
    if [[ -n "$chart_flag" ]]; then
        echo "   Charts: enabled (ZIP output)"
    fi
    echo ""

    for selection in $(echo "$USAGE_SELECTION" | tr -d '"'); do
        case "$selection" in
            bedrock_usage)
                echo "💰 Running Bedrock Cost & Per-User Usage report..."
                ./script/usage/bedrock_cost_usage_report.sh -b "$START_DATE" -e "$END_DATE" $region_flag
                ;;
            bedrock_token_usage)
                echo "🤖 Running Bedrock Token Usage (CloudWatch Metrics) report..."
                ./script/usage/bedrock_token_usage_report.sh -b "$START_DATE" -e "$END_DATE" $region_flag $chart_flag
                ;;
            quicksight_usage)
                echo "📈 Running QuickSight Usage report..."
                ./script/usage/quicksight_usage_report.sh -b "$START_DATE" -e "$END_DATE" $region_flag
                ;;
        esac
    done

    echo ""
    echo "✅ Usage reports complete!"
    echo "   Reports saved to: $OUTPUT_DIR/"
    if [[ -n "$chart_flag" && -f "$OUTPUT_DIR/bedrock_usage_report.zip" ]]; then
        echo "   📦 ZIP package: $OUTPUT_DIR/bedrock_usage_report.zip"
    fi
}

select_optimization_reports() {
    OPT_SELECTION=$(whiptail --title "$TITLE - Optimization Reports" --checklist \
"Select optimization reports (SPACE to toggle, ENTER to confirm):" 22 75 11 \
        "opt_ec2_rightsizing" "EC2 Right-Sizing recommendations" ON \
        "opt_rds_rightsizing" "RDS Right-Sizing recommendations" ON \
        "opt_idle_resources" "Idle Resource Detection" ON \
        "opt_ebs_optimization" "EBS Volume Optimization" ON \
        "opt_ri_sp_advisor" "RI / Savings Plans Advisor" OFF \
        "opt_data_transfer" "Data Transfer Cost Analysis" OFF \
        "opt_s3_storage" "S3 Storage Class Optimization" ON \
        "opt_efs_storage" "EFS Storage Optimization" OFF \
        "opt_cost_trend" "Cost Trend Analysis (period comparison)" OFF \
        "opt_trusted_advisor" "Trusted Advisor Cost Checks" OFF \
        "opt_summary" "Optimization Summary Report" ON \
        3>&1 1>&2 2>&3) || OPT_SELECTION=""
}

select_security_reports() {
    SEC_SELECTION=$(whiptail --title "$TITLE - Security Reports" --checklist \
"Select security reports (SPACE to toggle, ENTER to confirm):" 20 75 9 \
        "sec_trusted_advisor" "Trusted Advisor Security Checks" ON \
        "sec_iam_audit" "IAM Audit (users, policies, MFA)" ON \
        "sec_sg_audit" "Security Groups (open ports)" ON \
        "sec_s3_audit" "S3 Bucket Security (public access)" ON \
        "sec_encryption_audit" "Encryption Audit (EBS, RDS, S3)" ON \
        "sec_network_audit" "Network Security (VPC, NACLs)" ON \
        "sec_logging_audit" "Logging & Monitoring Coverage" ON \
        "sec_securityhub" "Security Hub Findings" OFF \
        "sec_summary" "Security Summary Report" ON \
        3>&1 1>&2 2>&3) || SEC_SELECTION=""
}

select_usage_reports() {
    USAGE_SELECTION=$(whiptail --title "$TITLE - Usage Reports" --checklist \
"Select usage reports (SPACE to toggle, ENTER to confirm):

Usage reports track service consumption metrics (tokens, sessions).
Charts option (-g) generates PNG charts + Excel packaged as ZIP." 18 75 4 \
        "bedrock_usage" "Bedrock Cost & Per-User Token (requires logging)" ON \
        "bedrock_token_usage" "Bedrock Token Usage from CloudWatch Metrics" ON \
        "quicksight_usage" "QuickSight Users & Cost" OFF \
        3>&1 1>&2 2>&3) || USAGE_SELECTION=""

    # Ask if they want chart generation
    if [[ -n "$USAGE_SELECTION" ]]; then
        if whiptail --title "$TITLE - Generate Charts" --yesno \
"Generate charts (PNG) + Excel report packaged as ZIP?

This creates visual graphs of token usage trends and a formatted
Excel workbook, all bundled into a downloadable ZIP file.

Requires: Python3 + matplotlib, pandas, openpyxl" 13 70; then
            GENERATE_USAGE_CHARTS=true
        else
            GENERATE_USAGE_CHARTS=false
        fi
    fi
}

input_date_range() {
    # Default: last 30 days
    DEFAULT_END=$(date +%Y-%m-%d)
    DEFAULT_START=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "2025-01-01")

    START_DATE=$(whiptail --title "$TITLE - Start Date" --inputbox \
"Enter START date (YYYY-MM-DD):

Used for CloudWatch metrics and Cost Explorer." 11 55 "$DEFAULT_START" \
        3>&1 1>&2 2>&3) || exit 0

    END_DATE=$(whiptail --title "$TITLE - End Date" --inputbox \
"Enter END date (YYYY-MM-DD):" 9 55 "$DEFAULT_END" \
        3>&1 1>&2 2>&3) || exit 0

    # Validate date format
    if ! date -d "$START_DATE" &>/dev/null 2>&1; then
        whiptail --title "Error" --msgbox "Invalid start date: $START_DATE\nUse YYYY-MM-DD format." 9 50
        input_date_range
    fi
    if ! date -d "$END_DATE" &>/dev/null 2>&1; then
        whiptail --title "Error" --msgbox "Invalid end date: $END_DATE\nUse YYYY-MM-DD format." 9 50
        input_date_range
    fi
}

input_regions() {
    REGIONS=$(whiptail --title "$TITLE - Regions" --inputbox \
"Enter AWS regions to scan (comma-separated):

  ap-southeast-1  Singapore
  ap-southeast-3  Jakarta
  us-east-1       N. Virginia
  eu-west-1       Ireland" 15 60 "ap-southeast-1,ap-southeast-3" \
        3>&1 1>&2 2>&3) || REGIONS="ap-southeast-1,ap-southeast-3"
}

select_parallel() {
    PARALLEL=$(whiptail --title "$TITLE - Execution Mode" --radiolist \
"Select execution mode:" 11 60 2 \
        "1" "Parallel (faster, recommended)" ON \
        "0" "Sequential (safer for large accounts)" OFF \
        3>&1 1>&2 2>&3) || PARALLEL="1"
}

select_debug_mode() {
    if whiptail --title "$TITLE - Debug Mode" --yesno \
"Enable debug mode?

Shows which config keys are enabled, tasks built,
and discovery details. Useful for troubleshooting." 11 60; then
        DEBUG_FLAG="--debug"
    else
        DEBUG_FLAG=""
    fi
}

select_excel_mode() {
    # Only show this for single-mode runs (not mode=all)
    if [[ "$MODE" == "all" ]]; then
        EXCEL_MODE="auto"  # mode=all always uses mode-sheets (3 sheets: Inventory/Opt/Sec)
        return
    fi

    EXCEL_MODE=$(whiptail --title "$TITLE - Excel Output" --radiolist \
"How should the Excel report be structured?" 12 70 2 \
        "single" "Single sheet (all reports combined, scrollable)" OFF \
        "multi" "Multi-sheet (1 sheet per AWS service)" ON \
        3>&1 1>&2 2>&3) || EXCEL_MODE="single"
}

select_report_method() {
    REPORT_METHOD=$(whiptail --title "$TITLE - Report Selection" --radiolist \
"How do you want to select which reports to run?" 13 70 3 \
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

    # Add excel-mode flag (only for single-mode runs, mode=all uses mode-sheets automatically)
    if [[ "$MODE" != "all" && -n "${EXCEL_MODE:-}" && "$EXCEL_MODE" != "auto" ]]; then
        CMD="$CMD --excel-mode $EXCEL_MODE"
    fi

    # Add auto-discover flag if selected
    if [[ -n "${AUTO_DISCOVER_FLAG:-}" ]]; then
        CMD="$CMD $AUTO_DISCOVER_FLAG"
    fi

    # Add debug flag if selected
    if [[ -n "${DEBUG_FLAG:-}" ]]; then
        CMD="$CMD $DEBUG_FLAG"
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
        if [[ -n "${COMPLIANCE_SELECTION:-}" ]]; then
            report_summary="${report_summary}Compliance: $(echo $COMPLIANCE_SELECTION | tr -d '"' | wc -w) reports\n"
        fi
        if [[ -n "${USAGE_SELECTION:-}" ]]; then
            report_summary="${report_summary}Usage: $(echo $USAGE_SELECTION | tr -d '"' | wc -w) reports\n"
            if [[ "${GENERATE_USAGE_CHARTS:-false}" == "true" ]]; then
                report_summary="${report_summary}  ↳ Charts + ZIP: enabled\n"
            fi
        fi
    fi

    if whiptail --title "$TITLE - Confirm" --yesno \
"Ready to run:

  Mode:       $MODE
  Start:      $START_DATE
  End:        $END_DATE
  Regions:    $REGIONS
  Parallel:   $( [[ "$PARALLEL" == "1" ]] && echo "Yes" || echo "No" )
  ${report_summary}
  Command: $CMD

Proceed?" 22 75; then
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

    # Enable selected compliance reports
    if [[ -n "${COMPLIANCE_SELECTION:-}" ]]; then
        for key in $(echo "$COMPLIANCE_SELECTION" | tr -d '"'); do
            set_config_key "$key" "1"
        done
    fi

    # Enable selected usage reports
    if [[ -n "${USAGE_SELECTION:-}" ]]; then
        for key in $(echo "$USAGE_SELECTION" | tr -d '"'); do
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

# Discovery mode has its own flow (no date range needed)
if [[ "$MODE" == "discovery" ]]; then
    input_regions
    select_discovery_scripts

    if [[ -z "$DISCOVERY_SELECTION" ]]; then
        whiptail --title "$TITLE" --msgbox "No discovery scripts selected. Exiting." 8 50
        exit 0
    fi

    if whiptail --title "$TITLE - Confirm Discovery" --yesno \
"Ready to run Architecture Discovery:

  Regions:  $REGIONS
  Scripts:  $(echo $DISCOVERY_SELECTION | tr -d '"' | tr ' ' ', ')

Queries your AWS infrastructure and generates Mermaid diagrams.

Proceed?" 14 70; then
        run_discovery
    else
        whiptail --title "$TITLE" --msgbox "Cancelled." 8 40
    fi
    exit 0
fi

# Usage mode has its own flow (needs date range + optional charts)
if [[ "$MODE" == "usage" ]]; then
    input_date_range

    # Ask if they want auto-discover regions or manual input
    USAGE_REGION_METHOD=$(whiptail --title "$TITLE - Region Selection" --radiolist \
"How do you want to select regions?" 11 70 2 \
        "auto" "Auto-detect from billing data (recommended)" ON \
        "manual" "Manual input" OFF \
        3>&1 1>&2 2>&3) || USAGE_REGION_METHOD="manual"

    if [[ "$USAGE_REGION_METHOD" == "auto" ]]; then
        # Auto-detect regions using Cost Explorer
        REGIONS="auto-detected"
        whiptail --title "$TITLE - Regions" --msgbox \
"Regions will be auto-detected from your billing data.

Services with Bedrock/QuickSight charges will be identified
and their regions used automatically." 10 70
    else
        input_regions
    fi

    select_usage_reports

    if [[ -z "$USAGE_SELECTION" ]]; then
        whiptail --title "$TITLE" --msgbox "No usage reports selected. Exiting." 8 50
        exit 0
    fi

    if whiptail --title "$TITLE - Confirm Usage Reports" --yesno \
"Ready to run Usage Reports:

  Period:   $START_DATE to $END_DATE
  Regions:  $REGIONS
  Reports:  $(echo $USAGE_SELECTION | tr -d '"' | tr ' ' ', ')
  Charts:   $( [[ "${GENERATE_USAGE_CHARTS:-false}" == "true" ]] && echo "Yes (ZIP)" || echo "No" )

Proceed?" 15 70; then
        run_usage
    else
        whiptail --title "$TITLE" --msgbox "Cancelled." 8 40
    fi
    exit 0
fi

input_date_range
select_parallel
select_debug_mode
select_excel_mode
select_report_method

# Region selection: auto-discover skips manual region input
if [[ "$REPORT_METHOD" == "auto" ]]; then
    # Auto-discover mode: regions will be auto-detected from billing
    AUTO_DISCOVER_FLAG="-a"
    REGIONS="auto-detected"
    whiptail --title "$TITLE - Regions" --msgbox \
"Regions will be auto-detected from your billing data.

To override, use CLI:
  ./main_report_runner.sh -b $START_DATE -e $END_DATE -a -r <regions>" 11 70
else
    # Manual mode: ask for regions
    input_regions
    AUTO_DISCOVER_FLAG=""
fi

# Show report selection based on mode and method
if [[ "$REPORT_METHOD" == "auto" ]]; then
    # Auto-discover:
    #   - Inventory: services auto-detected from billing (no checklist needed)
    #   - Optimize: user picks scripts, but regions auto-detected
    #   - Security: user picks scripts manually
    #   - Usage: user picks scripts manually
    case "$MODE" in
        optimize)
            # User picks which optimization reports to run; regions auto-detected
            select_optimization_reports
            ;;
        security)
            # User picks which security reports to run; regions auto-detected
            select_security_reports
            ;;
        usage)
            select_usage_reports
            ;;
        optimize,security)
            select_optimization_reports
            select_security_reports
            ;;
        all)
            # Inventory auto-discovered; user picks opt + sec + compliance + usage
            select_optimization_reports
            select_security_reports
            select_compliance_reports
            ;;
        inventory)
            # Inventory auto-discovered; compliance needs checklist
            select_compliance_reports
            ;;
    esac
elif [[ "$REPORT_METHOD" == "manual" ]]; then
    AUTO_DISCOVER_FLAG=""
    case "$MODE" in
        all)
            select_inventory_reports
            select_optimization_reports
            select_security_reports
            select_compliance_reports
            ;;
        inventory)
            select_inventory_reports
            select_compliance_reports
            ;;
        optimize)
            select_optimization_reports
            ;;
        security)
            select_security_reports
            ;;
        usage)
            select_usage_reports
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

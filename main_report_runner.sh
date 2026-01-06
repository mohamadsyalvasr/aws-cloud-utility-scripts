#!/bin/bash
# main_report_runner.sh
# Main script to run all AWS reporting scripts based on a configuration file.

set -euo pipefail

# --- Logging Functions with Status Symbols ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

log_start() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

log_success() {
    echo >&2 -e "[$(date +'%H:%M:%S')] ✅ $*"
}

log_error() {
    echo >&2 -e "[$(date +'%H:%M:%S')] ❌ $*"
}

# --- Main Script ---
log_start "🚀 Starting combined AWS report generation..."

# Set execute permissions for the dependency script
log_start "🔧 Setting execute permissions for dependency script..."
chmod +x ./dependencies.sh
log_success "Permissions set."

# Run the dependency installation script
./dependencies.sh

log_start "🔧 Setting execute permissions for all report scripts..."
chmod +x ./script/aws_ec2_report.sh
chmod +x ./script/aws_rds_report.sh
chmod +x ./script/aws_ri_report.sh
chmod +x ./script/aws_sp_report.sh
chmod +x ./script/ebs_report.sh
chmod +x ./script/ebs_utilization_report.sh
chmod +x ./script/aws_billing_report.sh
chmod +x ./script/s3_report.sh
chmod +x ./script/elasticache_report.sh
chmod +x ./script/eks_report.sh
chmod +x ./script/elb_report.sh
chmod +x ./script/efs_report.sh
chmod +x ./script/vpc_report.sh
chmod +x ./script/waf_report.sh
chmod +x ./script/aws_workspaces_report.sh
chmod +x ./script/aws_workspaces_report.sh
chmod +x ./script/iam_report.sh
chmod +x ./script/lambda_report.sh
chmod +x ./script/cloudfront_report.sh
chmod +x ./script/dynamodb_report.sh
chmod +x ./script/asg_report.sh
chmod +x ./script/ecs_report.sh
chmod +x ./script/vpn_report.sh
chmod +x ./combine_csv.py
log_success "✅ Permissions set."

# Check if the required scripts and config file exist
REQUIRED_SCRIPTS=(
    "./script/aws_ec2_report.sh"
    "./script/aws_rds_report.sh"
    "./script/ebs_report.sh"
    "./script/ebs_utilization_report.sh"
    "./script/aws_billing_report.sh"
    "./script/s3_report.sh"
    "./script/elasticache_report.sh"
    "./script/eks_report.sh"
    "./script/elb_report.sh"
    "./script/efs_report.sh"
    "./script/vpc_report.sh"
    "./script/waf_report.sh"
    "./script/aws_sp_report.sh"
    "./script/aws_ri_report.sh"
    "./script/aws_workspaces_report.sh"
    "./script/aws_ri_report.sh"
    "./script/aws_workspaces_report.sh"
    "./script/iam_report.sh"
    "./script/lambda_report.sh"
    "./script/cloudfront_report.sh"
    "./script/dynamodb_report.sh"
    "./script/asg_report.sh"
    "./script/ecs_report.sh"
    "./script/vpn_report.sh"
)

for script_path in "${REQUIRED_SCRIPTS[@]}"; do
    if [[ ! -f "$script_path" ]]; then
        log_error "Error: Required script not found: $script_path"
        log_error "Please ensure all scripts are in the correct directory."
        exit 1
    fi
done

if [[ ! -f "./config.ini" ]]; then
    log_error "Error: Configuration file config.ini not found. Please create it."
    exit 1
fi

# --- IMPORTANT: Interactive Check and Deletion of Previous Output Folder ---
# --- IMPORTANT: Interactive Check and Deletion of Previous Output Folder ---
OUTPUT_ROOT="export"

# 1. Define the output current date variables
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")

TODAY_DIR="aws-cloud-report-${YEAR}-${MONTH}-${DAY}"
# 2. Define and EXPORT OUTPUT_DIR to ensure child scripts (in ./script/) can save their files here.
export OUTPUT_DIR="${OUTPUT_ROOT}/${TODAY_DIR}"

if [[ -d "$OUTPUT_DIR" ]]; then
    log_start "🚨 Previous output folder detected: $OUTPUT_DIR"
    
    # Prompt the user for input. The -r option ensures raw input, -p displays the prompt.
    read -r -p "Do you want to DELETE the previous output folder? (y/N): " response
    
    # Check if the response is 'y' or 'Y'
    if [[ "$response" =~ ^([yY])$ ]]; then
        log_start "🗑️ Deleting previous output folder..."
        rm -rf "$OUTPUT_DIR"
        log_success "✅ Previous output folder successfully deleted."
    else
        log_start "⚠️ Previous output folder NOT deleted. Reports might function unexpectedly if files exist."
    fi
fi

log_start "📁 Creating clean output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"

# Check if the directory was successfully created
if [ $? -eq 0 ]; then
    log_success "✅ Output directory created: ${OUTPUT_DIR}"
else
    log_error "❌ FAILED to create output directory: ${OUTPUT_DIR}"
    exit 1
fi

# Read configuration from the INI file
source <(grep = config.ini | sed 's/ *= */=/g')

# Process flags from CLI arguments without requiring a hyphen
PASS_THROUGH_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|--regions) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -b|--begin) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export START_DATE="$1" ;;
        -e|--end) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export END_DATE="$1" ;;
        -s|--sum-ebs) PASS_THROUGH_ARGS+=("$1") ;;
        -f|--filename) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -h|--help)
            log_start "Usage: $0 <other_args>"
            log_start "  <other_args>: Arguments for the individual scripts (-r, -b, -e, -f, -s)."
            log_start "  To select which reports to run, edit the config.ini file."
            exit 0
            ;;
        *) PASS_THROUGH_ARGS+=("$1") ;;
    esac
    shift
done

# Function to run a report with only the necessary arguments
run_report_with_args() {
    local script_path="$1"
    shift
    local needed_args="$*"
    local run_args=()

    for arg in $needed_args; do
        for (( i=0; i<${#PASS_THROUGH_ARGS[@]}; i++ )); do
            if [[ "${PASS_THROUGH_ARGS[$i]}" == "$arg" ]]; then
                run_args+=("${PASS_THROUGH_ARGS[$i]}")
                if [[ "$arg" != "-s" ]]; then # Flags like -s don't have a value
                    run_args+=("${PASS_THROUGH_ARGS[$i+1]}")
                fi
            fi
        done
    done

    log_start "Running ${script_path} with arguments: ${run_args[*]}"
    "${script_path}" "${run_args[@]}"
    log_success "${script_path} finished."
}

# Run reports based on the configuration file
if [[ "$billing" == "1" ]]; then
    run_report_with_args "./script/aws_billing_report.sh" "-b -e"
fi

if [[ "$ebs_detailed" == "1" ]]; then
    run_report_with_args "./script/ebs_report.sh" "-r"
fi

if [[ "$ebs_utilization" == "1" ]]; then
    run_report_with_args "./script/ebs_utilization_report.sh" "-r -b -e"
fi

if [[ "$ec2" == "1" ]]; then
    run_report_with_args "./script/aws_ec2_report.sh" "-r -b -e -s"
fi

if [[ "$efs" == "1" ]]; then
    run_report_with_args "./script/efs_report.sh" "-r"
fi

if [[ "$eks" == "1" ]]; then
    run_report_with_args "./script/eks_report.sh" "-r"
fi

if [[ "$elb" == "1" ]]; then
    run_report_with_args "./script/elb_report.sh" "-r"
fi

if [[ "$elasticache" == "1" ]]; then
    run_report_with_args "./script/elasticache_report.sh" "-r"
fi

if [[ "$rds" == "1" ]]; then
    run_report_with_args "./script/aws_rds_report.sh" "-r -b -e"
fi

if [[ "$s3" == "1" ]]; then
    # S3 script uses environment variables, no need to pass args
    log_start "Running s3_report.sh..."
    ./script/s3_report.sh
    log_success "s3_report.sh finished."
fi

if [[ "$sp" == "1" ]]; then
    run_report_with_args "./script/aws_sp_report.sh" "-r"
fi

if [[ "$ri" == "1" ]]; then
    run_report_with_args "./script/aws_ri_report.sh" "-r"
fi

if [[ "$vpc" == "1" ]]; then
    run_report_with_args "./script/vpc_report.sh" "-r"
fi

if [[ "$waf" == "1" ]]; then
    run_report_with_args "./script/waf_report.sh" "-r -b -e"
fi

if [[ "$workspaces" == "1" ]]; then
    run_report_with_args "./script/aws_workspaces_report.sh" "-r"
fi

if [[ "$iam" == "1" ]]; then
    log_start "Running iam_report.sh..."
    ./script/iam_report.sh
    log_success "iam_report.sh finished."
fi

if [[ "$lambda" == "1" ]]; then
    run_report_with_args "./script/lambda_report.sh" "-r"
fi

if [[ "$cloudfront" == "1" ]]; then
    log_start "Running cloudfront_report.sh..."
    ./script/cloudfront_report.sh
    log_success "cloudfront_report.sh finished."
fi

if [[ "$dynamodb" == "1" ]]; then
    run_report_with_args "./script/dynamodb_report.sh" "-r"
fi

if [[ "$asg" == "1" ]]; then
    run_report_with_args "./script/asg_report.sh" "-r"
fi

if [[ "$ecs" == "1" ]]; then
    run_report_with_args "./script/ecs_report.sh" "-r"
fi

if [[ "$vpn" == "1" ]]; then
    run_report_with_args "./script/vpn_report.sh" "-r"
fi

log_success "All selected reports generated successfully."
# log_success "Your reports are now available in the current directory." # Baris ini dihapus atau diubah karena Excel belum dibuat

# --- GABUNGKAN CSV KE EXCEL ---
log_start "✨ Combining CSV reports into a single Excel file..."
# Panggil skrip Python dengan direktori output sebagai argumen
python3 ./combine_csv.py "${OUTPUT_DIR}"
# Cek apakah eksekusi Python berhasil
if [ $? -eq 0 ]; then
    log_success "✅ CSV reports successfully combined into Excel: ${OUTPUT_DIR}/Combined_AWS_Reports.xlsx"
else
    log_error "❌ FAILED to combine CSV reports into Excel."
    # Kita tetap melanjutkan ke zipping atau keluar, tergantung kebutuhan Anda.
fi
# ------------------------------

# --- ZIP the output folder ---
log_start "📦 Zipping output folder..."
ZIP_FILENAME="aws_reports_${YEAR}-${MONTH}-${DAY}.zip"

# The 'zip' command is executed here
zip -r "${ZIP_FILENAME}" "${OUTPUT_DIR}"

log_success "✅ All reports have been zipped to: ${ZIP_FILENAME}"

# --- Added: Display final location and copy/paste path ---
CURRENT_DIR=$(pwd)
log_success "📂 Report Location (Current Directory): ${CURRENT_DIR}"
log_success "📋 Copy/Paste Path for Download: ${CURRENT_DIR}/${ZIP_FILENAME}"

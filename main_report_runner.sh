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
chmod +x ./script/kms_report.sh
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
    "./script/kms_report.sh"
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

# Initialize Result Tracking (using temp files for background job compatibility)
RESULT_DIR=$(mktemp -d)
# Ensure cleanup on exit
trap 'rm -rf "$RESULT_DIR"' EXIT

# Function to record result
record_result() {
    local task_name="$1"
    local status="$2"
    echo "$status" > "${RESULT_DIR}/${task_name// /_}.status"
}

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

# Use default values for parallel settings if missing
PARALLEL_ENABLED="${parallel:-0}"
MAX_PARALLEL="${max_parallel:-3}"

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

# General function to execute a report (called by run_report_with_args or directly)
execute_task() {
    local script_path="$1"
    local run_args=("${@:2}")
    local task_name=$(basename "$script_path")

    log_start "🚀 Running ${task_name}..."
    
    # Run the script and capture exit code
    # Using 'set +e' temporarily to prevent script exit on report failure
    set +e
    if [[ ${#run_args[@]} -gt 0 ]]; then
        "${script_path}" "${run_args[@]}"
    else
        "${script_path}"
    fi
    local exit_code=$?
    set -e

    if [[ $exit_code -eq 0 ]]; then
        log_success "✅ ${task_name} finished successfully."
        record_result "$task_name" "SUCCESS"
    else
        log_error "❌ ${task_name} failed with exit code ${exit_code}."
        record_result "$task_name" "FAILED"
    fi
    return $exit_code
}

# Wrapper for run_report_with_args to collect arguments
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

# 1. Collect all reports to be executed
TASKS=()

if [[ "${billing:-0}" == "1" ]]; then
    TASKS+=("./script/aws_billing_report.sh|$(get_report_args "./script/aws_billing_report.sh" "-b -e")")
fi
if [[ "${ebs_detailed:-0}" == "1" ]]; then
    TASKS+=("./script/ebs_report.sh|$(get_report_args "./script/ebs_report.sh" "-r")")
fi
if [[ "${ebs_utilization:-0}" == "1" ]]; then
    TASKS+=("./script/ebs_utilization_report.sh|$(get_report_args "./script/ebs_utilization_report.sh" "-r -b -e")")
fi
if [[ "${ec2:-0}" == "1" ]]; then
    TASKS+=("./script/aws_ec2_report.sh|$(get_report_args "./script/aws_ec2_report.sh" "-r -b -e -s")")
fi
if [[ "${efs:-0}" == "1" ]]; then
    TASKS+=("./script/efs_report.sh|$(get_report_args "./script/efs_report.sh" "-r")")
fi
if [[ "${eks:-0}" == "1" ]]; then
    TASKS+=("./script/eks_report.sh|$(get_report_args "./script/eks_report.sh" "-r")")
fi
if [[ "${elb:-0}" == "1" ]]; then
    TASKS+=("./script/elb_report.sh|$(get_report_args "./script/elb_report.sh" "-r")")
fi
if [[ "${elasticache:-0}" == "1" ]]; then
    TASKS+=("./script/elasticache_report.sh|$(get_report_args "./script/elasticache_report.sh" "-r")")
fi
if [[ "${rds:-0}" == "1" ]]; then
    TASKS+=("./script/aws_rds_report.sh|$(get_report_args "./script/aws_rds_report.sh" "-r -b -e")")
fi
if [[ "${s3:-0}" == "1" ]]; then
    TASKS+=("./script/s3_report.sh|")
fi
if [[ "${sp:-0}" == "1" ]]; then
    TASKS+=("./script/aws_sp_report.sh|$(get_report_args "./script/aws_sp_report.sh" "-r")")
fi
if [[ "${ri:-0}" == "1" ]]; then
    TASKS+=("./script/aws_ri_report.sh|$(get_report_args "./script/aws_ri_report.sh" "-r")")
fi
if [[ "${vpc:-0}" == "1" ]]; then
    TASKS+=("./script/vpc_report.sh|$(get_report_args "./script/vpc_report.sh" "-r")")
fi
if [[ "${waf:-0}" == "1" ]]; then
    TASKS+=("./script/waf_report.sh|$(get_report_args "./script/waf_report.sh" "-r -b -e")")
fi
if [[ "${workspaces:-0}" == "1" ]]; then
    TASKS+=("./script/aws_workspaces_report.sh|$(get_report_args "./script/aws_workspaces_report.sh" "-r")")
fi
if [[ "${iam:-0}" == "1" ]]; then
    TASKS+=("./script/iam_report.sh|")
fi
if [[ "${kms:-0}" == "1" ]]; then
    TASKS+=("./script/kms_report.sh|$(get_report_args "./script/kms_report.sh" "-r")")
fi
if [[ "${lambda:-0}" == "1" ]]; then
    TASKS+=("./script/lambda_report.sh|$(get_report_args "./script/lambda_report.sh" "-r")")
fi
if [[ "${cloudfront:-0}" == "1" ]]; then
    TASKS+=("./script/cloudfront_report.sh|")
fi
if [[ "${dynamodb:-0}" == "1" ]]; then
    TASKS+=("./script/dynamodb_report.sh|$(get_report_args "./script/dynamodb_report.sh" "-r")")
fi
if [[ "${asg:-0}" == "1" ]]; then
    TASKS+=("./script/asg_report.sh|$(get_report_args "./script/asg_report.sh" "-r")")
fi
if [[ "${ecs:-0}" == "1" ]]; then
    TASKS+=("./script/ecs_report.sh|$(get_report_args "./script/ecs_report.sh" "-r")")
fi
if [[ "${vpn:-0}" == "1" ]]; then
    TASKS+=("./script/vpn_report.sh|$(get_report_args "./script/vpn_report.sh" "-r")")
fi

# 2. Run Collected Tasks
if [[ "$PARALLEL_ENABLED" == "1" ]]; then
    log_start "⏳ Running reports in PARALLEL mode (Max: ${MAX_PARALLEL})..."
    for task_info in "${TASKS[@]}"; do
        IFS='|' read -r script_path args <<< "$task_info"
        
        # Manage parallel limit
        while [[ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]]; do
            sleep 1
        done
        
        # Run task in background
        execute_task "$script_path" $args &
    done
    wait
else
    log_start "⏳ Running reports in SEQUENTIAL mode..."
    for task_info in "${TASKS[@]}"; do
        IFS='|' read -r script_path args <<< "$task_info"
        execute_task "$script_path" $args
    done
fi

log_success "Report generation process completed."

# --- GENERATE SUMMARY ---
echo "--------------------------------------------------"
echo "             AWS REPORTS SUMMARY                  "
echo "--------------------------------------------------"
TOTAL_TASKS=${#TASKS[@]}
SUCCESS_COUNT=$(ls -1 "${RESULT_DIR}"/*.status 2>/dev/null | xargs grep -l "SUCCESS" | wc -l)
FAILED_COUNT=$(ls -1 "${RESULT_DIR}"/*.status 2>/dev/null | xargs grep -l "FAILED" | wc -l)

echo "Total Reports Attempted: $TOTAL_TASKS"
echo "✅ Successful: $SUCCESS_COUNT"
echo "❌ Failed:     $FAILED_COUNT"

if [[ $FAILED_COUNT -gt 0 ]]; then
    echo -e "\nFailed Reports List:"
    for f in "${RESULT_DIR}"/*.status; do
        if grep -q "FAILED" "$f"; then
            task_file=$(basename "$f" .status)
            echo " - ${task_file//_/ }"
        fi
    done
fi
echo "--------------------------------------------------"

# If no reports were even attempted
if [[ $TOTAL_TASKS -eq 0 ]]; then
    log_error "No reports were selected in config.ini."
fi
# log_success "Your reports are now available in the current directory." # Baris ini dihapus atau diubah karena Excel belum dibuat

# --- GABUNGKAN CSV KE EXCEL ---
log_start "✨ Combining CSV reports into a single Excel file..."
# Panggil skrip Python dengan direktori output sebagai argumen
python3 ./combine_csv.py "${OUTPUT_DIR}"
# Cek apakah eksekusi Python berhasil
if [ $? -eq 0 ]; then
    log_success "✅ CSV reports successfully combined into Excel: ${OUTPUT_DIR}/Combined_AWS_Reports.xlsx"
    
    # Copy file Excel ke root directory (lokasi zip berada)
    cp "${OUTPUT_DIR}/Combined_AWS_Reports.xlsx" "./Combined_AWS_Reports.xlsx"
    log_success "✅ Combined_AWS_Reports.xlsx copied to current directory."
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
log_success "� Zip Archive Available: ${CURRENT_DIR}/${ZIP_FILENAME}"

if [ -f "./Combined_AWS_Reports.xlsx" ]; then
    log_success "📋 Copy/Paste Path for Download: ${CURRENT_DIR}/Combined_AWS_Reports.xlsx"
else
    log_success "�📋 Copy/Paste Path for Download: ${CURRENT_DIR}/${ZIP_FILENAME}"
fi

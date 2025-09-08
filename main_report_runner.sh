#!/bin/bash
# main_report_runner.sh
# Main script to run all AWS reporting scripts based on a configuration file.

set -euo pipefail

# --- Logging Functions with Status Symbols ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

log_start() {
    echo >&2 -e "[$(date +'%H:%M:%S')] 🚀 $*"
}

log_success() {
    echo >&2 -e "[$(date +'%H:%M:%S')] ✅ $*"
}

log_error() {
    echo >&2 -e "[$(date +'%H:%M:%S')] ❌ $*"
}

# --- Main Script ---
log_start "Starting combined AWS report generation..."

# Set execute permissions for all scripts
log "🔧 Setting execute permissions for all scripts..."
find . -type f -name "*.sh" -exec chmod +x {} \;
log_success "Permissions set."

# Run the dependency installation script
./dependencies.sh

# Check if the config file exists
if [[ ! -f "./config.ini" ]]; then
    log_error "Error: Configuration file config.ini not found. Please create it."
    exit 1
fi

# Create a dated output directory structure
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
log_start "📁 Creating output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"
log_success "Directory created."

# Read configuration from the INI file
source <(grep -vE '^\s*;' config.ini | sed 's/ *= */=/g')

# Map configuration variables to scripts and their required arguments
declare -A REPORT_MAP
REPORT_MAP["billing"]="./script/aws_billing_report.sh -b -e"
REPORT_MAP["ebs_detailed"]="./script/ebs_report.sh -r"
REPORT_MAP["ebs_utilization"]="./script/ebs_utilization_report.sh -r -b -e"
REPORT_MAP["ec2"]="./script/aws_ec2_report.sh -r -b -e -s"
REPORT_MAP["efs"]="./script/efs_report.sh -r"
REPORT_MAP["eks"]="./script/eks_report.sh -r"
REPORT_MAP["elb"]="./script/elb_report.sh -r"
REPORT_MAP["elasticache"]="./script/elasticache_report.sh -r"
REPORT_MAP["rds"]="./script/aws_rds_report.sh -r -b -e"
REPORT_MAP["s3"]="./script/s3_report.sh"
REPORT_MAP["sp"]="./script/aws_sp_report.sh -r"
REPORT_MAP["ri"]="./script/aws_ri_report.sh -r"
REPORT_MAP["vpc"]="./script/vpc_report.sh -r"
REPORT_MAP["waf"]="./script/waf_report.sh -r -b -e"
REPORT_MAP["workspaces"]="./script/aws_workspaces_report.sh -r"

# Process CLI arguments
PASS_THROUGH_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|--regions) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -b|--begin) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export START_DATE="$1" ;;
        -e|--end) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export END_DATE="$1" ;;
        -s|--sum-ebs) PASS_THROUGH_ARGS+=("$1") ;;
        -f|--filename) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -h|--help)
            log "Usage: $0 <other_args>"
            log "  <other_args>: Arguments for the individual scripts (-r, -b, -e, -f, -s)."
            log "  To select which reports to run, edit the config.ini file."
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
    local needed_args_list="$*"
    local run_args=()

    # Iterate through needed arguments
    for arg in $needed_args_list; do
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
for report in "${!REPORT_MAP[@]}"; do
    if [[ "${!report}" == "1" ]]; then
        local script_and_args=("${REPORT_MAP[$report]}")
        local script_path="${script_and_args[0]}"
        local args_list="${script_and_args[@]:1}"
        
        # Check if the script exists before attempting to run it
        if [[ ! -f "$script_path" ]]; then
            log_error "Error: Required script not found: $script_path"
            exit 1
        fi
        
        # Special case for S3 since it doesn't take args and uses env vars
        if [[ "$report" == "s3" ]]; then
            log_start "Running s3_report.sh..."
            ./script/s3_report.sh
            log_success "s3_report.sh finished."
        else
            run_report_with_args "$script_path" "$args_list"
        fi
    fi
done

log_success "All selected reports generated successfully."

# --- ZIP the output folder ---
log_start "📦 Zipping output folder..."
ZIP_FILENAME="aws_reports_${YEAR}-${MONTH}-${DAY}.zip"
zip -r "${ZIP_FILENAME}" "output"
log_success "✅ All reports have been zipped to: ${ZIP_FILENAME}"
#!/bin/bash
# main_report_runner.sh
# Main script to run all AWS reporting scripts based on a configuration file.

set -euo pipefail

# --- Logging Functions with Status Symbols ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

log_start() {
    echo >&2 -e "➡️  $*"
}

log_success() {
    echo >&2 -e "✅  $*"
}

log_error() {
    echo >&2 -e "❌  $*"
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
chmod +x ./script/aws_inventory.sh
chmod +x ./script/aws_sp_ri_report.sh
chmod +x ./script/ebs_report.sh
chmod +x ./script/ebs_utilization_report.sh
chmod +x ./script/aws_billing_report.sh
chmod +x ./script/s3_report.sh
chmod +x ./script/elasticache_report.sh
chmod +x ./script/eks_report.sh
chmod +x ./script/elb_report.sh
chmod +x ./script/efs_report.sh
chmod +x ./script/vpc_report.sh
log_success "✅ Permissions set."

# Check if the required scripts and config file exist
REQUIRED_SCRIPTS=(
    "./script/aws_inventory.sh"
    "./script/aws_sp_ri_report.sh"
    "./script/ebs_report.sh"
    "./script/ebs_utilization_report.sh"
    "./script/aws_billing_report.sh"
    "./script/s3_report.sh"
    "./script/elasticache_report.sh"
    "./script/eks_report.sh"
    "./script/elb_report.sh"
    "./script/efs_report.sh"
    "./script/vpc_report.sh"
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

# Create a dated output directory structure
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
log_start "📁 Creating output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"
log_success "✅ Directory created."

# Read configuration from the INI file
source <(grep = config.ini | sed 's/ *= */=/g')

# Process flags from CLI arguments without requiring a hyphen
PASS_THROUGH_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|--regions|-b|--begin|-e|--end|-f|--filename|-s|--sum-ebs) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
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

# Run reports based on the configuration file
if [[ "$inventory" == "1" ]]; then
    log_start "Running aws_inventory.sh..."
    ./script/aws_inventory.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "aws_inventory.sh finished."
fi

if [[ "$ebs_detailed" == "1" ]]; then
    log_start "Running ebs_report.sh..."
    ./script/ebs_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "ebs_report.sh finished."
fi

if [[ "$ebs_utilization" == "1" ]]; then
    log_start "Running ebs_report.sh..."
    ./script/ebs_utilization_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "ebs_report.sh finished."
fi

if [[ "$sp_ri" == "1" ]]; then
    log_start "Running aws_sp_ri_report.sh..."
    ./script/aws_sp_ri_report.sh
    log_success "aws_sp_ri_report.sh finished."
fi

if [[ "$billing" == "1" ]]; then
    log_start "Running aws_billing_report.sh..."
    ./script/aws_billing_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "aws_billing_report.sh finished."
fi

if [[ "$s3" == "1" ]]; then
    log_start "Running s3_report.sh..."
    ./script/s3_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "s3_report.sh finished."
fi

if [[ "$elasticache" == "1" ]]; then
    log_start "Running elasticache_report.sh..."
    ./script/elasticache_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "elasticache_report.sh finished."
fi

if [[ "$eks" == "1" ]]; then
    log_start "Running eks_report.sh..."
    ./script/eks_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "eks_report.sh finished."
fi

if [[ "$elb" == "1" ]]; then
    log_start "Running elb_report.sh..."
    ./script/elb_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "elb_report.sh finished."
fi

if [[ "$efs" == "1" ]]; then
    log_start "Running efs_report.sh..."
    ./script/efs_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "efs_report.sh finished."
fi

if [[ "$vpc" == "1" ]]; then
    log_start "Running vpc_report.sh..."
    ./script/vpc_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "vpc_report.sh finished."
fi

log_success "All selected reports generated successfully."
log_success "Your reports are now available in the current directory."


# --- ZIP the output folder ---
log_start "📦 Zipping output folder..."
ZIP_FILENAME="aws_reports_${YEAR}-${MONTH}-${DAY}.zip"
zip -r "${ZIP_FILENAME}" "output"
log_success "✅ All reports have been zipped to: ${ZIP_FILENAME}"

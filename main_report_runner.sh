#!/bin/bash
# main_report_runner.sh
# Main script to run all AWS reporting scripts based on a configuration file.

set -euo pipefail

# --- Logging Functions with Status Symbols ---
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
chmod +x ./script/aws_billing_report.sh
log_success "✅ Permissions set."

# Check if the required scripts and config file exist
if [[ ! -f "./script/aws_inventory.sh" || ! -f "./script/aws_sp_ri_report.sh" || ! -f "./script/ebs_report.sh" || ! -f "./script/aws_billing_report.sh" ]]; then
    log_error "Error: One or more required scripts are missing. Please ensure all scripts are in the same directory."
    exit 1
fi

if [[ ! -f "./config.ini" ]]; then
    log_error "Error: Configuration file config.ini not found. Please create it."
    exit 1
fi

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

if [[ "$ebs" == "1" ]]; then
    log_start "Running ebs_report.sh..."
    ./script/ebs_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "ebs_report.sh finished."
fi

if [[ "$sp-ri" == "1" ]]; then
    log_start "Running aws_sp_ri_report.sh..."
    ./script/aws_sp_ri_report.sh
    log_success "aws_sp_ri_report.sh finished."
fi

if [[ "$billing" == "1" ]]; then
    log_start "Running aws_billing_report.sh..."
    ./script/aws_billing_report.sh "${PASS_THROUGH_ARGS[@]}"
    log_success "aws_billing_report.sh finished."
fi

log_success "All selected reports generated successfully."
log_success "Your reports are now available in the current directory."

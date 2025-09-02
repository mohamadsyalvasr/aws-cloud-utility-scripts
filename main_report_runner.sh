#!/bin/bash
# main_report_runner.sh
# Main script to run all AWS reporting scripts sequentially.

set -euo pipefail

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Main Script ---
log "🚀 Starting combined AWS report generation..."

# Set execute permissions for all necessary scripts
log "🔧 Setting execute permissions for all report scripts..."
chmod +x ./aws_inventory_instance_report.sh
chmod +x ./aws_sp_ri_report.sh
chmod +x ./ebs_volume_report.sh
log "✅ Permissions set."


# Check if the required scripts exist
if [[ ! -f "./aws_inventory_instance_report.sh" || ! -f "./aws_sp_ri_report.sh" || ! -f "./ebs_volume_report.sh" ]]; then
    log "❌ Error: One or more required scripts (aws_inventory.sh, aws_sp_ri_report.sh, ebs_report.sh) are missing."
    log "Please ensure all scripts are in the same directory."
    exit 1
fi

# Run the inventory script (EC2 & RDS)
log "Running aws_inventory.sh..."
./aws_inventory_instance_report.sh "$@"

# Run the SP & RI report script
log "Running aws_sp_ri_report.sh..."
./aws_sp_ri_report.sh "$@"

# Run the EBS volume report script
log "Running ebs_report.sh..."
./ebs_volume_report.sh "$@"

log "✅ All reports generated successfully."
log "Your reports are now available in the current directory."

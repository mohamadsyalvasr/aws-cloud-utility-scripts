#!/bin/bash
# install_dependencies.sh
# Checks for and installs required dependencies for all reporting scripts.

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Utility Function: Install Dependencies ---
install_dependencies() {
    log "🔧 Checking and installing dependencies (jq and bc)..."
    if ! command -v jq >/dev/null 2>&1; then
        log "   jq not found. Installing..."
        # Use yum for RPM-based systems
        if command -v yum >/dev/null 2>&1; then
            sudo yum install -y jq
        else
            log "   Warning: Could not automatically install jq. Please install it manually."
        fi
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        log "   bc not found. Installing..."
        if command -v yum >/dev/null 2>&1; then
            sudo yum install -y bc
        else
            log "   Warning: Could not automatically install bc. Please install it manually."
        fi
    fi
    log "✅ Dependencies check complete."

    # Tambahkan baris ini ke dependencies.sh
    
    # Memastikan Python, pip, dan dependencies tersedia
    command -v python3 >/dev/null 2>&1 || { echo >&2 "Python 3 is required but not installed. Aborting."; exit 1; }
    command -v pip3 >/dev/null 2>&1 || { echo >&2 "pip3 is required but not installed. Aborting."; exit 1; }

    log_start "Installing Python libraries for CSV to Excel conversion (pandas, openpyxl, xlsxwriter)..."
    pip3 install pandas openpyxl xlsxwriter --break-system-packages || { log_error "Failed to install Python dependencies."; exit 1; }
    log_success "Python dependencies installed."
}

# Run the installation process
install_dependencies

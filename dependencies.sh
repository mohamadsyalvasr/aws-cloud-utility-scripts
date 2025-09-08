#!/bin/bash
# install_dependencies.sh
# Checks for and installs required dependencies for all reporting scripts.

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Helper Function: Check and install a single dependency ---
install_package() {
    local package_name="$1"
    if ! command -v "$package_name" &>/dev/null; then
        log "   '$package_name' not found. Installing..."
        if command -v dnf &>/dev/null; then
            sudo dnf install -y "$package_name"
        elif command -v yum &>/dev/null; then
            sudo yum install -y "$package_name"
        else
            log "   Warning: Could not automatically install '$package_name'. Please install it manually."
        fi
    fi
}

# --- Main Installation Function ---
install_dependencies() {
    log "🔧 Checking and installing dependencies (aws cli, jq, bc)..."
    # Ensure AWS CLI is installed
    install_package "aws"
    # Ensure jq is installed
    install_package "jq"
    # Ensure bc is installed for calculations
    install_package "bc"
    log "✅ Dependencies check complete."
}

# Run the installation process
install_dependencies
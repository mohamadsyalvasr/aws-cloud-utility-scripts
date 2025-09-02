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
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo apt-get update && sudo apt-get install -y jq
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            brew install jq
        else
            log "   Warning: Could not automatically install jq. Please install it manually."
        fi
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        log "   bc not found. Installing..."
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sudo apt-get update && sudo apt-get install -y bc
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            brew install bc
        else
            log "   Warning: Could not automatically install bc. Please install it manually."
        fi
    fi
    log "✅ Dependencies check complete."
}

# Run the installation process
install_dependencies

#!/bin/bash
# install_dependencies.sh
# Checks for and installs required dependencies for all reporting scripts.

# --- Logging Function ---
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

# --- Utility Function: Install Dependencies ---
install_dependencies() {
    log_start "🔧 Checking and installing system dependencies (jq and bc)..."
    
    # Instalasi jq
    if ! command -v jq >/dev/null 2>&1; then
        log_start "   jq not found. Installing..."
        if command -v yum >/dev/null 2>&1; then
            sudo yum install -y jq
        else
            log_error "   Error: Could not automatically install jq. Please install it manually."
            return 1
        fi
    fi
    
    # Instalasi bc
    if ! command -v bc >/dev/null 2>&1; then
        log_start "   bc not found. Installing..."
        if command -v yum >/dev/null 2>&1; then
            sudo yum install -y bc
        else
            log_error "   Error: Could not automatically install bc. Please install it manually."
            return 1
        fi
    fi
    log_success "System dependencies check complete."
    
    # --- Python Dependencies ---
    log_start "🔧 Installing Python libraries for CSV to Excel conversion (pandas, openpyxl, xlsxwriter)..."
    
    # Memastikan Python dan pip tersedia
    if ! command -v python3 >/dev/null 2>&1; then
        log_error "   Error: python3 is required but not installed. Aborting Python dependency installation."
        return 0 # Gagal instalasi Python tidak menghentikan keseluruhan script, tapi Excel tidak akan dibuat.
    fi
    
    if ! command -v pip3 >/dev/null 2>&1; then
        log_error "   Error: pip3 is required but not installed. Aborting Python dependency installation."
        return 0
    fi

    # Mencoba instalasi tanpa flag --break-system-packages yang bermasalah.
    # Mencoba instalasi tanpa sudo (untuk lingkungan virtual/user), kemudian dengan sudo jika gagal.
    if pip3 install pandas openpyxl xlsxwriter >/dev/null 2>&1; then
        log_success "Python dependencies installed."
    else
        log_start "   Warning: Installation failed without sudo. Trying with sudo..."
        if sudo pip3 install pandas openpyxl xlsxwriter; then
            log_success "Python dependencies installed with sudo."
        else
            log_error "   Error: Gagal menginstal Python dependencies. Harap instal 'pandas', 'openpyxl', dan 'xlsxwriter' secara manual."
            return 0
        fi
    fi
    
    return 0
}

# Run the installation process
install_dependencies
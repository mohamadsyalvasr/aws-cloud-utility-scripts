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

# Function to parse INI file
parse_ini() {
    local ini_file="$1"
    local section="$2"
    local key="$3"
    
    local value=$(sed -n "/\[$section\]/,/\[.*\]/p" "$ini_file" | grep "^$key" | cut -d'=' -f2 | xargs)
    echo "$value"
}

# Function to prompt for credential method
prompt_for_credentials() {
    if [[ ! -f "./aws_credentials.ini" ]]; then
        log_error "Error: Credentials file aws_credentials.ini not found. Using default AWS credentials."
        return
    fi

    # Find all profile names in the credentials file
    local profiles=$(grep -Eo '\[.*\]' ./aws_credentials.ini | tr -d '[]' | tr '\n' ' ')
    local profile_array=($profiles)

    log "Pilih profil akun AWS yang akan digunakan:"
    for i in "${!profile_array[@]}"; do
        echo "$((i+1)). ${profile_array[$i]}"
    done
    echo "0. Gunakan kredensial default dari lingkungan"
    echo "A. Jalankan untuk SEMUA akun"

    read -p "Masukkan pilihan Anda (0-${#profile_array[@]} atau A): " choice
    
    if [[ "$choice" == "A" || "$choice" == "a" ]]; then
        log "Jalankan laporan untuk SEMUA akun..."
        for profile in "${profile_array[@]}"; do
            run_reports_for_profile "$profile"
        done
        # Exit after running all accounts
        exit 0
    elif [[ "$choice" -eq 0 ]]; then
        log "Menggunakan kredensial AWS default dari lingkungan."
    elif [[ "$choice" -gt 0 && "$choice" -le "${#profile_array[@]}" ]]; then
        local selected_profile="${profile_array[$((choice-1))]}"
        run_reports_for_profile "$selected_profile"
        # Exit after running single account
        exit 0
    else
        log_error "Pilihan tidak valid. Menggunakan kredensial AWS default."
    fi
}

# Function to run reports for a specific profile
run_reports_for_profile() {
    local selected_profile="$1"
    
    log_start "Menjalankan laporan untuk profil: ${selected_profile}"

    # Load the selected profile's credentials from the file
    local access_key=$(parse_ini "./aws_credentials.ini" "$selected_profile" "aws_access_key_id")
    local secret_key=$(parse_ini "./aws_credentials.ini" "$selected_profile" "aws_secret_access_key")

    if [[ -z "$access_key" || -z "$secret_key" ]]; then
        log_error "Access key ID atau secret access key tidak ditemukan untuk profil: $selected_profile. Melewati profil ini."
        return
    else
        export AWS_ACCESS_KEY_ID="$access_key"
        export AWS_SECRET_ACCESS_KEY="$secret_key"
    fi

    # Create a dated and account-specific output directory
    YEAR=$(date +"%Y")
    MONTH=$(date +"%m")
    DAY=$(date +"%d")
    OUTPUT_DIR="output/${selected_profile}/${YEAR}/${MONTH}/${DAY}"
    log "📁 Creating output directory: ${OUTPUT_DIR}/"
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
    
    # Run reports based on the configuration file
    for report in "${!REPORT_MAP[@]}"; do
        if [[ "${!report}" == "1" ]]; then
            local script_and_args=("${REPORT_MAP[$report]}")
            local script_path="${script_and_args[0]}"
            local args_list="${script_and_args[@]:1}"
            
            # Check if the script exists before attempting to run it
            if [[ ! -f "$script_path" ]]; then
                log_error "Error: Required script not found: $script_path"
                continue
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

    log_success "Semua laporan untuk profil ${selected_profile} selesai."
}

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

# Prompt for credentials method
prompt_for_credentials

log_success "All selected reports generated successfully."

# --- ZIP the output folder ---
log_start "📦 Zipping output folder..."
ZIP_FILENAME="aws_reports_${YEAR}-${MONTH}-${DAY}.zip"
zip -r "${ZIP_FILENAME}" "output"
log_success "✅ All reports have been zipped to: ${ZIP_FILENAME}"

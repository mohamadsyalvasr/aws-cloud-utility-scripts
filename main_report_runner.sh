#!/bin/bash
# main_report_runner.sh
# Main orchestrator script for AWS report generation.
# Reads config.ini, runs enabled reports, combines to Excel, and zips output.

set -euo pipefail

# --- Load Modules ---
source ./lib/logger.sh
source ./lib/task_runner.sh
source ./lib/report_registry.sh

# --- Start ---
log_start "🚀 Starting combined AWS report generation..."

# --- Install Dependencies ---
log_start "🔧 Installing dependencies..."
chmod +x ./dependencies.sh
./dependencies.sh

# --- Set Permissions & Validate ---
log_start "🔧 Setting execute permissions..."
set_script_permissions
log_success "Permissions set."

validate_scripts

if [[ ! -f "./config.ini" ]]; then
    log_error "Configuration file config.ini not found."
    exit 1
fi

# --- Output Directory Setup ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
export OUTPUT_DIR="export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}"

if [[ -d "$OUTPUT_DIR" ]]; then
    log_start "🚨 Previous output folder detected: $OUTPUT_DIR"
    read -r -p "Do you want to DELETE the previous output folder? (y/N): " response
    if [[ "$response" =~ ^([yY])$ ]]; then
        rm -rf "$OUTPUT_DIR"
        log_success "Previous output folder deleted."
    else
        log_start "⚠️ Previous output folder NOT deleted."
    fi
fi

# --- Result Tracking ---
RESULT_DIR=$(mktemp -d)
trap 'rm -rf "$RESULT_DIR"' EXIT
export RESULT_DIR

log_start "📁 Creating output directory: ${OUTPUT_DIR}/"
mkdir -p "${OUTPUT_DIR}"
log_success "Output directory created: ${OUTPUT_DIR}"

# --- Read Configuration ---
source <(grep -v '^\s*[;#]' config.ini | grep -v '^\s*$' | grep '=' | sed 's/\r//g' | sed 's/ *= */=/g')

PARALLEL_ENABLED="${parallel:-0}"
MAX_PARALLEL="${max_parallel:-3}"

# --- Parse CLI Arguments ---
PASS_THROUGH_ARGS=()
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|--regions) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -b|--begin)   PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export START_DATE="$1" ;;
        -e|--end)     PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export END_DATE="$1" ;;
        -s|--sum-ebs) PASS_THROUGH_ARGS+=("$1") ;;
        -f|--filename) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -h|--help)
            echo "Usage: $0 -b <start_date> -e <end_date> [-r regions] [-s] [-f filename]"
            echo "  Edit config.ini to select which reports to run."
            exit 0
            ;;
        *) PASS_THROUGH_ARGS+=("$1") ;;
    esac
    shift
done

# --- Build & Run Tasks ---
build_task_list
run_tasks "$PARALLEL_ENABLED" "$MAX_PARALLEL"

# --- Summary ---
print_summary

# --- Remove empty CSV files (header-only, no data) ---
log_start "🧹 Removing empty CSV files (header-only)..."
REMOVED_COUNT=0
shopt -s nullglob
for csv_file in "${OUTPUT_DIR}"/*.csv; do
    # Count lines: if only 1 line (header) or 0 lines, remove
    line_count=$(wc -l < "$csv_file")
    if [[ "$line_count" -le 1 ]]; then
        rm -f "$csv_file"
        REMOVED_COUNT=$((REMOVED_COUNT + 1))
    fi
done
shopt -u nullglob
if [[ $REMOVED_COUNT -gt 0 ]]; then
    log_success "Removed $REMOVED_COUNT empty CSV files."
else
    log_success "No empty CSV files found."
fi

# --- Combine CSV to Excel ---
log_start "✨ Combining CSV reports into a single Excel file..."
if python3 ./combine_csv.py "${OUTPUT_DIR}"; then
    EXCEL_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "Combined_AWS_Reports_*.xlsx" 2>/dev/null | head -1)
    if [[ -n "$EXCEL_FILE" && -f "$EXCEL_FILE" ]]; then
        EXCEL_BASENAME=$(basename "$EXCEL_FILE")
        log_success "CSV reports combined into Excel: ${EXCEL_FILE}"
        cp "$EXCEL_FILE" "./${EXCEL_BASENAME}"
        log_success "${EXCEL_BASENAME} copied to current directory."
    else
        log_error "Excel file not found after combining."
    fi
else
    log_error "FAILED to combine CSV reports into Excel."
fi

# --- Combine Optimization Reports to Excel ---
# Only run if at least one optimization report is enabled
OPT_ENABLED=0
for opt_key in opt_ec2_rightsizing opt_rds_rightsizing opt_idle_resources opt_ebs_optimization opt_ri_sp_advisor opt_data_transfer opt_s3_storage opt_efs_storage opt_summary; do
    raw_value="${!opt_key:-0}"
    clean_value=$(echo "$raw_value" | tr -d '[:space:]')
    if [[ "$clean_value" == "1" ]]; then
        OPT_ENABLED=1
        break
    fi
done

if [[ "$OPT_ENABLED" == "1" ]]; then
    log_start "✨ Combining optimization reports into a single Excel file..."
    if python3 ./combine_optimization_excel.py "${OUTPUT_DIR}"; then
        OPT_EXCEL_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "AWS_Optimization_Report_*.xlsx" 2>/dev/null | head -1)
        if [[ -n "$OPT_EXCEL_FILE" && -f "$OPT_EXCEL_FILE" ]]; then
            OPT_EXCEL_BASENAME=$(basename "$OPT_EXCEL_FILE")
            log_success "Optimization reports combined into Excel: ${OPT_EXCEL_FILE}"
            cp "$OPT_EXCEL_FILE" "./${OPT_EXCEL_BASENAME}"
            log_success "${OPT_EXCEL_BASENAME} copied to current directory."
        else
            log_error "Optimization Excel file not found after combining."
        fi
    else
        log_error "FAILED to combine optimization reports into Excel."
    fi
fi

# --- Zip Output ---
log_start "📦 Zipping output folder..."
ZIP_FILENAME="aws_reports_${YEAR}-${MONTH}-${DAY}.zip"
zip -r "${ZIP_FILENAME}" "${OUTPUT_DIR}"
log_success "All reports zipped to: ${ZIP_FILENAME}"

# --- Final Info ---
CURRENT_DIR=$(pwd)
log_success "📂 Report Location: ${CURRENT_DIR}"
log_success "📦 Zip Archive: ${CURRENT_DIR}/${ZIP_FILENAME}"
if [[ -n "${EXCEL_BASENAME:-}" && -f "./${EXCEL_BASENAME}" ]]; then
    log_success "📋 Download Path: ${CURRENT_DIR}/${EXCEL_BASENAME}"
else
    log_success "📋 Download Path: ${CURRENT_DIR}/${ZIP_FILENAME}"
fi

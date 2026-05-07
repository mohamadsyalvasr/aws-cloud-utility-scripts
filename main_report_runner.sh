#!/bin/bash
# main_report_runner.sh
# Main orchestrator script for AWS report generation.
# Reads config.ini, runs enabled reports, combines to Excel, and zips output.

set -euo pipefail

# --- Load Modules ---
source ./lib/logger.sh
source ./lib/task_runner.sh
source ./lib/report_registry.sh
source ./lib/notifier.sh
source ./lib/auto_discover.sh

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
export RUN_MODE="all"
AUTO_DISCOVER="${AUTO_DISCOVER:-false}"
EXCEL_MODE="${EXCEL_MODE:-single}"
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -r|--regions) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -b|--begin)   PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export START_DATE="$1" ;;
        -e|--end)     PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1"); export END_DATE="$1" ;;
        -s|--sum-ebs) PASS_THROUGH_ARGS+=("$1") ;;
        -f|--filename) PASS_THROUGH_ARGS+=("$1"); shift; PASS_THROUGH_ARGS+=("$1") ;;
        -m|--mode)    shift; RUN_MODE="$1" ;;
        -a|--auto-discover) AUTO_DISCOVER=true ;;
        --excel-mode) shift; EXCEL_MODE="$1" ;;
        -h|--help)
            echo "Usage: $0 -b <start_date> -e <end_date> [-r regions] [-m mode] [-a] [-s] [-f filename]"
            echo ""
            echo "Options:"
            echo "  -b, --begin <date>   Start date (YYYY-MM-DD) — required"
            echo "  -e, --end <date>     End date (YYYY-MM-DD) — required"
            echo "  -r, --regions        Comma-separated AWS regions"
            echo "  -m, --mode           Run mode: all, inventory, optimize, security (comma-separated)"
            echo "  -a, --auto-discover  Auto-enable reports based on billing data (requires Cost Explorer access)"
            echo "  --excel-mode <mode>  Excel output: single (1 sheet) or multi (1 sheet per service). Default: single"
            echo "                       Note: mode=all always generates 3 sheets (Inventory/Optimization/Security)"
            echo "  -s, --sum-ebs        Sum attached EBS volumes in EC2 report"
            echo "  -f, --filename       Custom output filename"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Modes (comma-separated for multiple):"
            echo "  all                Run all enabled reports (default)"
            echo "  inventory          Run only inventory reports"
            echo "  optimize           Run only price optimization reports (opt_* keys)"
            echo "  security           Run only security check reports (sec_* keys)"
            echo "  optimize,security  Run both optimization and security (skip inventory)"
            echo ""
            echo "Examples:"
            echo "  $0 -b 2025-08-01 -e 2025-08-31                    # Run all"
            echo "  $0 -b 2025-08-01 -e 2025-08-31 -m optimize       # Only optimization"
            echo "  $0 -b 2025-08-01 -e 2025-08-31 -m optimize,security  # Opt + Security"
            echo "  $0 -b 2025-08-01 -e 2025-08-31 --auto-discover   # Auto-discover from billing"
            echo ""
            echo "  Edit config.ini to select which reports to run within each mode."
            exit 0
            ;;
        *) PASS_THROUGH_ARGS+=("$1") ;;
    esac
    shift
done

log_start "📋 Run mode: ${RUN_MODE}"

# --- Auto-Discovery (if enabled) ---
if [[ "$AUTO_DISCOVER" == "true" ]]; then
    # Reset ALL inventory config keys to 0 first (auto-discover will selectively enable)
    # This prevents config.ini values from overriding auto-discovery
    log_start "🔄 Auto-discover mode: resetting inventory config keys..."
    for definition in "${REPORT_DEFINITIONS[@]}"; do
        IFS='|' read -r config_key _ _ <<< "$definition"
        # Only reset inventory keys (no prefix) — leave opt_ and sec_ alone
        if [[ "$config_key" != opt_* && "$config_key" != sec_* ]]; then
            eval "export ${config_key}=0"
        fi
    done

    if auto_discover_services "$START_DATE" "$END_DATE"; then
        log_success "Using auto-discovered service configuration"
    else
        log_start "⚠️ Service auto-discovery failed. Restoring config.ini settings."
        # Re-source config.ini to restore original values
        source <(grep -v '^\s*[;#]' config.ini | grep -v '^\s*$' | grep '=' | sed 's/\r//g' | sed 's/ *= */=/g')
    fi

    # Auto-discover regions (only if -r was NOT explicitly provided)
    REGIONS_EXPLICITLY_SET=false
    for arg in "${PASS_THROUGH_ARGS[@]}"; do
        if [[ "$arg" == "-r" || "$arg" == "--regions" ]]; then
            REGIONS_EXPLICITLY_SET=true
            break
        fi
    done

    if [[ "$REGIONS_EXPLICITLY_SET" == "false" ]]; then
        if auto_discover_regions "$START_DATE" "$END_DATE"; then
            # Inject discovered regions into PASS_THROUGH_ARGS
            PASS_THROUGH_ARGS+=("-r" "$DISCOVERED_REGIONS")
            log_success "Using auto-discovered regions: $DISCOVERED_REGIONS"
        else
            log_start "⚠️ Region auto-discovery failed. Using default regions."
        fi
    else
        log_start "   Regions explicitly set via -r flag, skipping region auto-discovery."
    fi
fi

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

# --- Combine Reports to Excel ---
# Logic:
#   mode=all → 1 Excel file with 3 sheets: "Inventory", "Optimization", "Security"
#              (each sheet contains all CSVs of that type combined)
#   mode=single (inventory/optimize/security) → depends on EXCEL_MODE:
#     EXCEL_MODE=single → all reports in 1 sheet (default, current behavior)
#     EXCEL_MODE=multi  → 1 sheet per AWS service/report file

if [[ "$RUN_MODE" == "all" ]]; then
    # --- MODE=ALL: Generate 1 combined Excel with sheets per mode ---
    log_start "✨ Generating combined Excel (1 sheet per mode)..."
    if python3 ./lib/python/combine_csv.py "${OUTPUT_DIR}" --mode-sheets; then
        EXCEL_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "Combined_AWS_Reports_*.xlsx" 2>/dev/null | head -1)
        if [[ -n "$EXCEL_FILE" && -f "$EXCEL_FILE" ]]; then
            EXCEL_BASENAME=$(basename "$EXCEL_FILE")
            log_success "Combined report: ${EXCEL_FILE}"
            cp "$EXCEL_FILE" "./${EXCEL_BASENAME}"
            log_success "${EXCEL_BASENAME} copied to current directory."
        else
            log_error "Excel file not found after combining."
        fi
    else
        log_error "FAILED to combine reports into Excel."
    fi

else
    # --- SINGLE MODE: Generate Excel based on EXCEL_MODE setting ---

    # Inventory Excel
    if [[ "$RUN_MODE" == *"inventory"* ]]; then
        local_excel_flag=""
        if [[ "$EXCEL_MODE" == "multi" ]]; then
            local_excel_flag="--multi-sheet"
        fi
        log_start "✨ Combining inventory reports into Excel (${EXCEL_MODE} sheet mode)..."
        if python3 ./lib/python/combine_csv.py "${OUTPUT_DIR}" $local_excel_flag; then
            EXCEL_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "Combined_AWS_Reports_*.xlsx" 2>/dev/null | head -1)
            if [[ -n "$EXCEL_FILE" && -f "$EXCEL_FILE" ]]; then
                EXCEL_BASENAME=$(basename "$EXCEL_FILE")
                log_success "Inventory Excel: ${EXCEL_FILE}"
                cp "$EXCEL_FILE" "./${EXCEL_BASENAME}"
                log_success "${EXCEL_BASENAME} copied to current directory."
            else
                log_error "Inventory Excel file not found."
            fi
        else
            log_error "FAILED to combine inventory reports."
        fi
    fi

    # Optimization Excel
    if [[ "$RUN_MODE" == *"optimize"* ]]; then
        OPT_ENABLED=0
        for opt_key in opt_ec2_rightsizing opt_rds_rightsizing opt_idle_resources opt_ebs_optimization opt_ri_sp_advisor opt_data_transfer opt_s3_storage opt_efs_storage opt_trusted_advisor opt_cost_trend opt_summary; do
            raw_value="${!opt_key:-0}"
            clean_value=$(echo "$raw_value" | tr -d '[:space:]')
            if [[ "$clean_value" == "1" ]]; then
                OPT_ENABLED=1
                break
            fi
        done

        if [[ "$OPT_ENABLED" == "1" ]]; then
            log_start "✨ Combining optimization reports into Excel (multi-sheet)..."
            if python3 ./lib/python/combine_optimization_excel.py "${OUTPUT_DIR}"; then
                OPT_EXCEL_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "AWS_Optimization_Report_*.xlsx" 2>/dev/null | head -1)
                if [[ -n "$OPT_EXCEL_FILE" && -f "$OPT_EXCEL_FILE" ]]; then
                    OPT_EXCEL_BASENAME=$(basename "$OPT_EXCEL_FILE")
                    log_success "Optimization Excel: ${OPT_EXCEL_FILE}"
                    cp "$OPT_EXCEL_FILE" "./${OPT_EXCEL_BASENAME}"
                    log_success "${OPT_EXCEL_BASENAME} copied to current directory."
                else
                    log_error "Optimization Excel file not found."
                fi
            else
                log_error "FAILED to combine optimization reports."
            fi
        fi
    fi

    # Security Excel
    if [[ "$RUN_MODE" == *"security"* ]]; then
        SEC_ENABLED=0
        for sec_key in sec_trusted_advisor sec_iam_audit sec_sg_audit sec_s3_audit sec_encryption_audit sec_network_audit sec_logging_audit sec_securityhub sec_summary; do
            raw_value="${!sec_key:-0}"
            clean_value=$(echo "$raw_value" | tr -d '[:space:]')
            if [[ "$clean_value" == "1" ]]; then
                SEC_ENABLED=1
                break
            fi
        done

        if [[ "$SEC_ENABLED" == "1" ]]; then
            log_start "✨ Combining security reports into Excel (multi-sheet)..."
            if python3 ./lib/python/combine_security_excel.py "${OUTPUT_DIR}"; then
                SEC_EXCEL_FILE=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "AWS_Security_Report_*.xlsx" 2>/dev/null | head -1)
                if [[ -n "$SEC_EXCEL_FILE" && -f "$SEC_EXCEL_FILE" ]]; then
                    SEC_EXCEL_BASENAME=$(basename "$SEC_EXCEL_FILE")
                    log_success "Security Excel: ${SEC_EXCEL_FILE}"
                    cp "$SEC_EXCEL_FILE" "./${SEC_EXCEL_BASENAME}"
                    log_success "${SEC_EXCEL_BASENAME} copied to current directory."
                else
                    log_error "Security Excel file not found."
                fi
            else
                log_error "FAILED to combine security reports."
            fi
        fi
    fi
fi

# --- Zip Output ---
log_start "📦 Zipping output folder..."
ZIP_FILENAME="aws_reports_${YEAR}-${MONTH}-${DAY}.zip"
zip -r "${ZIP_FILENAME}" "${OUTPUT_DIR}"
log_success "All reports zipped to: ${ZIP_FILENAME}"

# --- Send Notifications ---
send_notifications || true

# --- Final Info ---
CURRENT_DIR=$(pwd)
log_success "📂 Report Location: ${CURRENT_DIR}"
log_success "📦 Zip Archive: ${CURRENT_DIR}/${ZIP_FILENAME}"
if [[ -n "${EXCEL_BASENAME:-}" && -f "./${EXCEL_BASENAME}" ]]; then
    log_success "📋 Download Path: ${CURRENT_DIR}/${EXCEL_BASENAME}"
else
    log_success "📋 Download Path: ${CURRENT_DIR}/${ZIP_FILENAME}"
fi

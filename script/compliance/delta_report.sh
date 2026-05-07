#!/bin/bash
# script/delta_report.sh
# Historical Comparison / Delta Report
# Compares current run's CSV output against a baseline directory to identify
# NEW, REMOVED, and CHANGED AWS resources.
#
# This script makes NO AWS API calls. It reads CSVs from OUTPUT_DIR (current)
# and export/baseline/ (baseline), diffs them by Resource ID.

set -euo pipefail

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependency Check ---
for cmd in awk sort; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
BASELINE_DIR="export/baseline/"
CURRENT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
UPDATE_BASELINE=false

# --- Usage ---
usage() {
    cat <<EOF
Usage: $0 [--baseline <path>] [--current <path>] [--update-baseline] [-h]

Compare current CSV reports against a baseline to detect resource changes.

Options:
  --baseline <path>      Baseline directory path (default: export/baseline/)
  --current <path>       Current directory path (default: \$OUTPUT_DIR)
  --update-baseline      Copy current CSVs to baseline after comparison
  -h, --help             Show this help

Output:
  delta_report.csv in the current directory with columns:
  "Change Type","Resource Type","Resource ID","Resource Name","Changed Field","Old Value","New Value","Region"

First Run:
  If no baseline exists, the current run is copied to baseline and a
  header-only delta_report.csv is produced.
EOF
    exit 0
}

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --baseline)        shift; BASELINE_DIR="$1" ;;
        --current)         shift; CURRENT_DIR="$1" ;;
        --update-baseline) UPDATE_BASELINE=true ;;
        -h|--help)         usage ;;
        *) ;; # Ignore unknown args (pass-through from framework)
    esac
    shift
done

# --- Validate Current Directory ---
if [[ ! -d "$CURRENT_DIR" ]]; then
    log "❌ Current directory does not exist: $CURRENT_DIR"
    log "   Cannot proceed without current report data."
    exit 1
fi

OUTPUT_PATH="${CURRENT_DIR}/delta_report.csv"
CSV_HEADER='"Change Type","Resource Type","Resource ID","Resource Name","Changed Field","Old Value","New Value","Region"'

# --- Helper Functions ---

derive_resource_type() {
    local filename="$1"
    # Strip path and extension
    local base
    base=$(basename "$filename" .csv)
    # Strip aws_ prefix
    base="${base#aws_}"
    # Strip _report suffix
    base="${base%_report}"
    # Uppercase
    echo "$base" | tr '[:lower:]' '[:upper:]'
}

detect_id_column() {
    local header="$1"
    local col_idx=1
    IFS=',' read -ra fields <<< "$header"
    for field in "${fields[@]}"; do
        local clean
        clean=$(echo "$field" | tr -d '"' | tr '[:lower:]' '[:upper:]')
        if [[ "$clean" == *"ID"* || "$clean" == *"ARN"* ]]; then
            echo "$col_idx"
            return
        fi
        col_idx=$((col_idx + 1))
    done
    echo "0"
}

detect_name_column() {
    local header="$1"
    local col_idx=1
    IFS=',' read -ra fields <<< "$header"
    for field in "${fields[@]}"; do
        local clean
        clean=$(echo "$field" | tr -d '"' | tr '[:lower:]' '[:upper:]')
        if [[ "$clean" == *"NAME"* ]]; then
            echo "$col_idx"
            return
        fi
        col_idx=$((col_idx + 1))
    done
    echo "0"
}

detect_region_column() {
    local header="$1"
    local col_idx=1
    IFS=',' read -ra fields <<< "$header"
    for field in "${fields[@]}"; do
        local clean
        clean=$(echo "$field" | tr -d '"' | tr '[:lower:]' '[:upper:]')
        if [[ "$clean" == *"REGION"* ]]; then
            echo "$col_idx"
            return
        fi
        col_idx=$((col_idx + 1))
    done
    echo "0"
}

copy_to_baseline() {
    mkdir -p "$BASELINE_DIR"
    local count=0
    for csv_file in "${CURRENT_DIR}"/*.csv; do
        [[ -f "$csv_file" ]] || continue
        local base
        base=$(basename "$csv_file")
        # Skip delta_report.csv itself
        [[ "$base" == "delta_report.csv" ]] && continue
        cp "$csv_file" "${BASELINE_DIR}/${base}"
        count=$((count + 1))
    done
    log "  Copied $count CSV files to baseline: $BASELINE_DIR"
}

compare_csv() {
    local baseline_file="$1"
    local current_file="$2"
    local resource_type="$3"
    local output_file="$4"

    # Read headers
    local baseline_header current_header
    baseline_header=$(head -1 "$baseline_file" 2>/dev/null || echo "")
    current_header=$(head -1 "$current_file" 2>/dev/null || echo "")

    if [[ -z "$current_header" ]]; then
        log "  ⚠️  Empty file: $(basename "$current_file"), skipping"
        return
    fi

    # Detect ID column from current header
    local id_col
    id_col=$(detect_id_column "$current_header")
    if [[ "$id_col" == "0" ]]; then
        log "  ⚠️  No ID column found in $(basename "$current_file"), skipping"
        return
    fi

    # Detect name and region columns
    local name_col region_col
    name_col=$(detect_name_column "$current_header")
    region_col=$(detect_region_column "$current_header")

    # Get column headers as array
    IFS=',' read -ra col_headers <<< "$current_header"
    local num_cols=${#col_headers[@]}

    # Use awk to perform the comparison
    awk -F',' -v id_col="$id_col" -v name_col="$name_col" -v region_col="$region_col" \
        -v resource_type="$resource_type" -v num_cols="$num_cols" \
        -v output_file="$output_file" '
    BEGIN {
        # Read column headers from first file
        header_read = 0
    }
    # Process baseline file (first file via FILENAME)
    FNR == 1 && NR == FNR {
        # First line of baseline = header
        split($0, hdr_fields, ",")
        for (i=1; i<=NF; i++) {
            gsub(/"/, "", hdr_fields[i])
            col_names[i] = hdr_fields[i]
        }
        header_read = 1
        next
    }
    FILENAME == ARGV[1] && FNR > 1 {
        # Baseline data rows
        id_val = $id_col
        gsub(/"/, "", id_val)
        if (id_val != "") {
            baseline[id_val] = $0
        }
        next
    }
    # Process current file (second file)
    FILENAME == ARGV[2] && FNR == 1 {
        # Skip header of current file
        next
    }
    FILENAME == ARGV[2] && FNR > 1 {
        id_val = $id_col
        gsub(/"/, "", id_val)
        if (id_val == "") next

        # Get name
        res_name = ""
        if (name_col > 0 && name_col <= NF) {
            res_name = $name_col
            gsub(/"/, "", res_name)
        } else if (id_col < NF) {
            # Use first non-ID column
            for (c=1; c<=NF; c++) {
                if (c != id_col) { res_name = $c; gsub(/"/, "", res_name); break }
            }
        }

        # Get region
        region = "Global"
        if (region_col > 0 && region_col <= NF) {
            region = $region_col
            gsub(/"/, "", region)
        }

        if (id_val in baseline) {
            # Check for changes
            split(baseline[id_val], base_fields, ",")
            split($0, curr_fields, ",")
            for (c=1; c<=NF; c++) {
                if (c == id_col) continue
                bval = base_fields[c]; gsub(/"/, "", bval)
                cval = curr_fields[c]; gsub(/"/, "", cval)
                if (bval != cval) {
                    cname = col_names[c]
                    if (cname == "") cname = "Column_" c
                    printf "\"CHANGED\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", resource_type, id_val, res_name, cname, bval, cval, region >> output_file
                    changed_count++
                }
            }
            delete baseline[id_val]
            current_seen[id_val] = 1
        } else {
            # NEW resource
            printf "\"NEW\",\"%s\",\"%s\",\"%s\",\"\",\"\",\"\",\"%s\"\n", resource_type, id_val, res_name, region >> output_file
            new_count++
        }
    }
    END {
        # Remaining baseline entries are REMOVED
        for (id_val in baseline) {
            split(baseline[id_val], base_fields, ",")
            res_name = ""
            if (name_col > 0) {
                res_name = base_fields[name_col]
                gsub(/"/, "", res_name)
            }
            region = "Global"
            if (region_col > 0) {
                region = base_fields[region_col]
                gsub(/"/, "", region)
            }
            printf "\"REMOVED\",\"%s\",\"%s\",\"%s\",\"\",\"\",\"\",\"%s\"\n", resource_type, id_val, res_name, region >> output_file
            removed_count++
        }
    }
    ' "$baseline_file" "$current_file"
}

# =============================================================================
# Main Logic
# =============================================================================

log "📊 Delta Report — Comparing current vs baseline"
log "   Current:  $CURRENT_DIR"
log "   Baseline: $BASELINE_DIR"

# --- First-Run Detection ---
if [[ ! -d "$BASELINE_DIR" ]]; then
    log "ℹ️  No baseline found — creating baseline from current run"
    copy_to_baseline
    echo "$CSV_HEADER" > "$OUTPUT_PATH"
    log "✅ Baseline created. Header-only delta_report.csv written."
    log "   Next run will compare against this baseline."
    exit 0
fi

# --- Write Output Header ---
echo "$CSV_HEADER" > "$OUTPUT_PATH"

# --- Match CSV Files ---
TOTAL_COMPARED=0
TOTAL_NEW=0
TOTAL_REMOVED=0
TOTAL_CHANGED=0

log "🔍 Comparing CSV files..."

shopt -s nullglob
for current_csv in "${CURRENT_DIR}"/*.csv; do
    local_base=$(basename "$current_csv")

    # Skip non-report files
    [[ "$local_base" == "delta_report.csv" ]] && continue
    [[ "$local_base" == "cross_account_summary.csv" ]] && continue
    [[ "$local_base" == "scorecard_report.csv" ]] && continue

    local_baseline_csv="${BASELINE_DIR}/${local_base}"

    # Skip if no matching baseline file
    if [[ ! -f "$local_baseline_csv" ]]; then
        log "  ⚠️  No baseline for: $local_base (treating all as NEW)"
        # All rows in current are NEW
        local resource_type
        resource_type=$(derive_resource_type "$local_base")
        local id_col
        local header
        header=$(head -1 "$current_csv" 2>/dev/null || echo "")
        id_col=$(detect_id_column "$header")
        if [[ "$id_col" != "0" && -n "$header" ]]; then
            local name_col region_col
            name_col=$(detect_name_column "$header")
            region_col=$(detect_region_column "$header")
            awk -F',' -v id_col="$id_col" -v name_col="$name_col" -v region_col="$region_col" \
                -v resource_type="$resource_type" -v output_file="$OUTPUT_PATH" '
            NR > 1 {
                id_val = $id_col; gsub(/"/, "", id_val)
                if (id_val == "") next
                res_name = ""
                if (name_col > 0) { res_name = $name_col; gsub(/"/, "", res_name) }
                region = "Global"
                if (region_col > 0) { region = $region_col; gsub(/"/, "", region) }
                printf "\"NEW\",\"%s\",\"%s\",\"%s\",\"\",\"\",\"\",\"%s\"\n", resource_type, id_val, res_name, region >> output_file
            }' "$current_csv"
        fi
        TOTAL_COMPARED=$((TOTAL_COMPARED + 1))
        continue
    fi

    # Compare matched files
    local resource_type
    resource_type=$(derive_resource_type "$local_base")

    # Count rows before comparison for delta tracking
    local before_lines
    before_lines=$(wc -l < "$OUTPUT_PATH" | tr -d '[:space:]')

    compare_csv "$local_baseline_csv" "$current_csv" "$resource_type" "$OUTPUT_PATH"

    local after_lines
    after_lines=$(wc -l < "$OUTPUT_PATH" | tr -d '[:space:]')
    local delta_rows=$((after_lines - before_lines))

    if [[ $delta_rows -gt 0 ]]; then
        log "  📝 $local_base: $delta_rows change(s) detected"
    fi

    TOTAL_COMPARED=$((TOTAL_COMPARED + 1))
done
shopt -u nullglob

# Count totals from output file
if [[ -f "$OUTPUT_PATH" ]]; then
    TOTAL_NEW=$(grep -c '^"NEW"' "$OUTPUT_PATH" 2>/dev/null || echo "0")
    TOTAL_REMOVED=$(grep -c '^"REMOVED"' "$OUTPUT_PATH" 2>/dev/null || echo "0")
    TOTAL_CHANGED=$(grep -c '^"CHANGED"' "$OUTPUT_PATH" 2>/dev/null || echo "0")
fi

# --- Update Baseline (if requested) ---
if [[ "$UPDATE_BASELINE" == "true" ]]; then
    log "📋 Updating baseline with current data..."
    copy_to_baseline
fi

# --- Summary ---
log ""
log "═══════════════════════════════════════════════════════"
log "  Delta Report Summary"
log "═══════════════════════════════════════════════════════"
log "  Files compared:    $TOTAL_COMPARED"
log "  NEW resources:     $TOTAL_NEW"
log "  REMOVED resources: $TOTAL_REMOVED"
log "  CHANGED fields:    $TOTAL_CHANGED"
log "  Output:            $OUTPUT_PATH"
log "═══════════════════════════════════════════════════════"

#!/bin/bash
# sec_summary_report.sh
# Security Summary Report - Aggregates all security findings by category and severity.
# Reads all sec_*.csv files from OUTPUT_DIR and produces a summary.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/sec_summary_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
Options:
  -r <regions>   Not used. Accepted for framework compatibility.
  -f <filename>  Custom output filename.
  -h             Show this help message.
EOF
    exit 1
}

while getopts "r:f:h" opt; do
    case "$opt" in
        r) : ;; # Accepted but not used
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
for cmd in awk; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Setup ---
mkdir -p "$(dirname "$OUTPUT_FILE")"

# --- Category Name Mapping ---
get_category_name() {
    local filename="$1"
    case "$filename" in
        sec_trusted_advisor.csv)   echo "Trusted Advisor" ;;
        sec_iam_audit.csv)         echo "IAM Audit" ;;
        sec_sg_audit.csv)          echo "Security Groups" ;;
        sec_s3_audit.csv)          echo "S3 Buckets" ;;
        sec_encryption_audit.csv)  echo "Encryption" ;;
        sec_network_audit.csv)     echo "Network Security" ;;
        sec_logging_audit.csv)     echo "Logging & Monitoring" ;;
        sec_securityhub.csv)       echo "Security Hub" ;;
        *)                         echo "$filename" ;;
    esac
}

# --- Source Type ---
get_source_type() {
    local filename="$1"
    case "$filename" in
        sec_trusted_advisor.csv) echo "TA" ;;
        *)                       echo "Manual" ;;
    esac
}

# --- Main ---
log "📊 Security Summary Report"
log "✍️ Preparing output file: $OUTPUT_FILE"

# Write CSV header
printf '"Category","Critical","High","Medium","Low","Total"\n' > "$OUTPUT_FILE"

# Find all sec_*.csv files (excluding our own output)
SEC_FILES=()
for f in "${OUTPUT_DIR}"/sec_*.csv; do
    if [[ -f "$f" ]] && [[ "$(basename "$f")" != "sec_summary_report.csv" ]]; then
        SEC_FILES+=("$f")
    fi
done

if [[ ${#SEC_FILES[@]} -eq 0 ]]; then
    log "  ⚠️ No security CSV files found in $OUTPUT_DIR"
    printf '"No findings","0","0","0","0","0"\n' >> "$OUTPUT_FILE"
    log "✅ DONE. No security data to summarize."
    exit 0
fi

log "  Found ${#SEC_FILES[@]} security report file(s)"

TOTAL_CRITICAL=0
TOTAL_HIGH=0
TOTAL_MEDIUM=0
TOTAL_LOW=0
TOTAL_ALL=0

FILE_IDX=0
FILE_COUNT=${#SEC_FILES[@]}

for csv_file in "${SEC_FILES[@]}"; do
    FILE_IDX=$((FILE_IDX + 1))
    BASENAME=$(basename "$csv_file")
    CATEGORY=$(get_category_name "$BASENAME")
    SOURCE=$(get_source_type "$BASENAME")

    log "  [$FILE_IDX/$FILE_COUNT] Processing: $BASENAME ($SOURCE)"

    # Count findings by severity using awk (skip header row)
    # CSV format: "Finding","Resource","Detail","Severity","Recommendation","Region"
    # Severity is field 4
    CRITICAL=0
    HIGH=0
    MEDIUM=0
    LOW=0

    if [[ -f "$csv_file" ]]; then
        # Use awk to parse CSV and count severities
        COUNTS=$(awk -F'","' 'NR > 1 && NF >= 4 {
            # Remove leading/trailing quotes from severity field
            sev = $4
            gsub(/^"/, "", sev)
            gsub(/"$/, "", sev)
            if (sev == "Critical") critical++
            else if (sev == "High") high++
            else if (sev == "Medium") medium++
            else if (sev == "Low") low++
        }
        END {
            printf "%d %d %d %d", critical+0, high+0, medium+0, low+0
        }' "$csv_file")

        CRITICAL=$(echo "$COUNTS" | awk '{print $1}')
        HIGH=$(echo "$COUNTS" | awk '{print $2}')
        MEDIUM=$(echo "$COUNTS" | awk '{print $3}')
        LOW=$(echo "$COUNTS" | awk '{print $4}')
    fi

    FILE_TOTAL=$((CRITICAL + HIGH + MEDIUM + LOW))

    # Only add row if there are findings
    if [[ $FILE_TOTAL -gt 0 ]]; then
        printf '"%s (%s)","%d","%d","%d","%d","%d"\n' \
            "$CATEGORY" "$SOURCE" "$CRITICAL" "$HIGH" "$MEDIUM" "$LOW" "$FILE_TOTAL" >> "$OUTPUT_FILE"

        TOTAL_CRITICAL=$((TOTAL_CRITICAL + CRITICAL))
        TOTAL_HIGH=$((TOTAL_HIGH + HIGH))
        TOTAL_MEDIUM=$((TOTAL_MEDIUM + MEDIUM))
        TOTAL_LOW=$((TOTAL_LOW + LOW))
        TOTAL_ALL=$((TOTAL_ALL + FILE_TOTAL))

        log "    Critical=$CRITICAL, High=$HIGH, Medium=$MEDIUM, Low=$LOW (Total=$FILE_TOTAL)"
    else
        log "    No findings"
    fi
done

# Add TOTAL row
printf '"TOTAL","%d","%d","%d","%d","%d"\n' \
    "$TOTAL_CRITICAL" "$TOTAL_HIGH" "$TOTAL_MEDIUM" "$TOTAL_LOW" "$TOTAL_ALL" >> "$OUTPUT_FILE"

log ""
log "  ═══════════════════════════════════════════"
log "  Summary: Critical=$TOTAL_CRITICAL, High=$TOTAL_HIGH, Medium=$TOTAL_MEDIUM, Low=$TOTAL_LOW"
log "  Total findings: $TOTAL_ALL"
log "  ═══════════════════════════════════════════"
log ""
log "✅ DONE. Security summary report saved to: $OUTPUT_FILE"

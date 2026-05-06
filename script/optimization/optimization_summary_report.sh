#!/bin/bash
# optimization_summary_report.sh
# Generates a consolidated summary of all optimization recommendations,
# aggregating findings from individual category CSV reports.

set -euo pipefail

# --- Configuration and Arguments ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/optimization_summary_report.csv"
REGIONS=("ap-southeast-1" "ap-southeast-3")
START_DATE=""
END_DATE=""

usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: The start date for the analysis period (YYYY-MM-DD).
  -e <end_date>    REQUIRED: The end date for the analysis period (YYYY-MM-DD).
  -r <regions>     Comma-separated list of AWS regions. Default: ap-southeast-1,ap-southeast-3
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

# Add a log function for this script to be self-contained
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# Process command-line arguments
while getopts "b:e:r:f:h" opt; do
    case "$opt" in
        b)
            START_DATE="$OPTARG"
            ;;
        e)
            END_DATE="$OPTARG"
            ;;
        r)
            IFS=',' read -r -a REGIONS <<< "$OPTARG"
            ;;
        f)
            OUTPUT_FILE="$OPTARG"
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

# --- Main Script ---
log "📊 Optimization Summary Report"
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Category","Resource Count","Total Monthly Savings","Top Recommendation","Priority"\n' > "$OUTPUT_FILE"

# --- Helper Functions ---

# Parse a CSV file and extract savings data
# Arguments:
#   $1 - CSV file path
#   $2 - Column number (1-based) for the savings value
#   $3 - Column number (1-based) for the recommendation text (resource identifier or recommendation)
# Outputs to stdout: resource_count|total_savings|top_recommendation|top_savings
parse_category_csv() {
    local csv_file="$1"
    local savings_col="$2"
    local recommendation_col="$3"

    if [ ! -f "$csv_file" ]; then
        echo "0|0.00||0.00"
        return 0
    fi

    # Use awk to parse CSV (handles quoted fields with embedded commas)
    awk -v savings_col="$savings_col" -v rec_col="$recommendation_col" '
    # Function to parse CSV line respecting quoted fields
    function parse_csv(line, fields,    i, n, in_quotes, field, c) {
        n = 0
        in_quotes = 0
        field = ""
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "\"") {
                in_quotes = !in_quotes
            } else if (c == "," && !in_quotes) {
                n++
                fields[n] = field
                field = ""
            } else {
                field = field c
            }
        }
        n++
        fields[n] = field
        return n
    }
    BEGIN {
        count = 0
        total_savings = 0
        top_savings = 0
        top_rec = ""
    }
    NR == 1 { next }  # Skip header
    {
        n = parse_csv($0, fields)

        # Get recommendation value
        rec_val = fields[rec_col]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", rec_val)
        if (rec_val == "N/A" || rec_val == "Insufficient Data") next

        # Get savings value
        savings_val = fields[savings_col]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", savings_val)
        if (savings_val == "N/A" || savings_val == "" || savings_val == "Insufficient Data") next

        # Convert to number
        savings_num = savings_val + 0

        count++
        total_savings += savings_num

        if (savings_num > top_savings) {
            top_savings = savings_num
            top_rec = rec_val
        }
    }
    END {
        printf "%d|%.2f|%s|%.2f\n", count, total_savings, top_rec, top_savings
    }
    ' "$csv_file"
}

# Classify priority based on total savings
# Arguments: $1 - total savings amount
# Returns: High, Medium, or Low
classify_priority() {
    local savings="$1"
    # Use awk for floating point comparison
    echo "$savings" | awk '{
        if ($1 + 0 > 100) print "High"
        else if ($1 + 0 >= 20) print "Medium"
        else print "Low"
    }'
}

# --- Category Definitions ---
# Format: csv_filename|category_name|savings_column|recommendation_column
# The recommendation_column is used to identify the "top recommendation" (the resource/action with highest savings)
# For most reports, we use the "Recommendation" or equivalent column
# For EC2/RDS right-sizing, we use the "Recommended Type/Class" column
CATEGORIES=(
    "ec2_rightsizing_report.csv|EC2 Right-Sizing|9|6"
    "rds_rightsizing_report.csv|RDS Right-Sizing|10|7"
    "idle_resources_report.csv|Idle Resources|6|7"
    "ebs_optimization_report.csv|EBS Optimization|8|7"
    "ri_sp_advisor_report.csv|RI/SP Advisor|6|7"
    "data_transfer_optimization_report.csv|Data Transfer|7|6"
    "s3_storage_optimization_report.csv|S3 Storage|8|7"
    "efs_storage_optimization_report.csv|EFS Storage|9|8"
)

# --- Process Each Category ---
GRAND_TOTAL_COUNT=0
GRAND_TOTAL_SAVINGS=0.00
GLOBAL_TOP_REC=""
GLOBAL_TOP_SAVINGS=0.00

for category_def in "${CATEGORIES[@]}"; do
    IFS='|' read -r csv_filename category_name savings_col rec_col <<< "$category_def"

    csv_path="${OUTPUT_DIR}/${csv_filename}"

    if [ -f "$csv_path" ]; then
        log "  Processing: $category_name ($csv_filename)"
    else
        log "  Skipping: $category_name ($csv_filename not found)"
    fi

    # Parse the CSV
    result=$(parse_category_csv "$csv_path" "$savings_col" "$rec_col")

    IFS='|' read -r resource_count total_savings top_rec top_savings <<< "$result"

    # Classify priority
    priority=$(classify_priority "$total_savings")

    # Update grand totals
    GRAND_TOTAL_COUNT=$((GRAND_TOTAL_COUNT + resource_count))
    GRAND_TOTAL_SAVINGS=$(echo "$GRAND_TOTAL_SAVINGS + $total_savings" | bc -l | awk '{printf "%.2f", $1}')

    # Track global top recommendation
    is_higher=$(echo "$top_savings" | awk -v global="$GLOBAL_TOP_SAVINGS" '{if ($1 + 0 > global + 0) print "1"; else print "0"}')
    if [ "$is_higher" = "1" ]; then
        GLOBAL_TOP_SAVINGS="$top_savings"
        GLOBAL_TOP_REC="$top_rec"
    fi

    # Handle empty top recommendation
    if [ -z "$top_rec" ]; then
        top_rec="N/A"
    fi

    # Write category row
    printf '"%s","%s","%.2f","%s","%s"\n' \
        "$category_name" \
        "$resource_count" \
        "$total_savings" \
        "$top_rec" \
        "$priority" >> "$OUTPUT_FILE"

    if [ "$resource_count" -gt 0 ]; then
        log "    Found $resource_count resource(s), total savings: \$${total_savings}/month [$priority]"
    fi
done

# --- Write Total Row ---
TOTAL_PRIORITY=$(classify_priority "$GRAND_TOTAL_SAVINGS")

if [ -z "$GLOBAL_TOP_REC" ]; then
    GLOBAL_TOP_REC="N/A"
fi

printf '"%s","%s","%.2f","%s","%s"\n' \
    "TOTAL" \
    "$GRAND_TOTAL_COUNT" \
    "$GRAND_TOTAL_SAVINGS" \
    "$GLOBAL_TOP_REC" \
    "$TOTAL_PRIORITY" >> "$OUTPUT_FILE"

log "✅ DONE. Optimization Summary report saved to: $OUTPUT_FILE"
log "   Total resources with recommendations: $GRAND_TOTAL_COUNT"
log "   Total potential monthly savings: \$${GRAND_TOTAL_SAVINGS}"
log "   Overall priority: $TOTAL_PRIORITY"

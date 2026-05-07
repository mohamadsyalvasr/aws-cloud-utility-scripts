#!/bin/bash
# cost_trend_report.sh
# Compares service-level costs between two consecutive time periods using
# AWS Cost Explorer, calculates dollar and percentage changes, assigns alert
# levels, and outputs a combined top-services CSV report.

set -euo pipefail

# --- Log Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/cost_trend_report.csv"
COST_CHANGE_THRESHOLD="${COST_CHANGE_THRESHOLD:-20}"

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-f filename] [-h]

Options:
  -b <start_date>  REQUIRED: Start date for Current Period (YYYY-MM-DD).
  -e <end_date>    REQUIRED: End date for Current Period (YYYY-MM-DD).
  -f <filename>    Custom filename for the output CSV file.
  -h               Show this help message.
EOF
    exit 1
}

# --- Argument Parsing ---
START_DATE=""
END_DATE=""

while getopts "b:e:f:h" opt; do
    case "$opt" in
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$START_DATE" ] || [ -z "$END_DATE" ]; then
    log "❌ Arguments -b and -e are required."
    usage
fi

# --- Dependency Check ---
log "🔎 Checking dependencies (aws, jq, bc)..."
for cmd in aws jq bc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log "❌ Required dependency not found: $cmd"
        exit 1
    fi
done
log "✅ Dependencies met."

# --- Calculate Previous Period ---
# Duration in days between start and end
DURATION_DAYS=$(( ( $(date -d "$END_DATE" +%s) - $(date -d "$START_DATE" +%s) ) / 86400 ))
PREV_START=$(date -d "$START_DATE - $DURATION_DAYS days" +%Y-%m-%d)
PREV_END="$START_DATE"

log "📊 Cost Trend Analysis (Threshold: ${COST_CHANGE_THRESHOLD}%)"
log "   Current Period:  $START_DATE to $END_DATE ($DURATION_DAYS days)"
log "   Previous Period: $PREV_START to $PREV_END ($DURATION_DAYS days)"

# --- Query Cost Explorer: Current Period ---
log "📡 Querying Cost Explorer for Current Period..."

set +e
CURRENT_RESULT=$(aws ce get-cost-and-usage \
    --time-period Start="$START_DATE",End="$END_DATE" \
    --granularity MONTHLY \
    --group-by Type=DIMENSION,Key=SERVICE \
    --metrics UnblendedCost \
    --output json 2>&1)
CURRENT_EXIT=$?
set -e

if [ $CURRENT_EXIT -ne 0 ]; then
    if echo "$CURRENT_RESULT" | grep -qi "AccessDenied\|AccessDeniedException"; then
        log "❌ Cost Explorer AccessDenied: Ensure your account has Cost Explorer access enabled."
        exit 1
    else
        log "❌ Cost Explorer error (Current Period): $CURRENT_RESULT"
        exit 1
    fi
fi

# --- Query Cost Explorer: Previous Period ---
log "📡 Querying Cost Explorer for Previous Period..."

set +e
PREVIOUS_RESULT=$(aws ce get-cost-and-usage \
    --time-period Start="$PREV_START",End="$PREV_END" \
    --granularity MONTHLY \
    --group-by Type=DIMENSION,Key=SERVICE \
    --metrics UnblendedCost \
    --output json 2>&1)
PREVIOUS_EXIT=$?
set -e

if [ $PREVIOUS_EXIT -ne 0 ]; then
    if echo "$PREVIOUS_RESULT" | grep -qi "AccessDenied\|AccessDeniedException"; then
        log "❌ Cost Explorer AccessDenied: Ensure your account has Cost Explorer access enabled."
        exit 1
    else
        log "❌ Cost Explorer error (Previous Period): $PREVIOUS_RESULT"
        exit 1
    fi
fi

# --- Parse JSON and Build Associative Arrays ---
log "🔄 Processing results..."

declare -A CURRENT_COSTS
declare -A PREVIOUS_COSTS

# Parse current period: sum costs across time buckets per service
while IFS='|' read -r service cost; do
    [ -z "$service" ] && continue
    existing="${CURRENT_COSTS[$service]:-0}"
    CURRENT_COSTS[$service]=$(echo "$existing + $cost" | bc -l)
done < <(echo "$CURRENT_RESULT" | jq -r '
    .ResultsByTime[].Groups[] |
    "\(.Keys[0])|\(.Metrics.UnblendedCost.Amount)"
')

# Parse previous period: sum costs across time buckets per service
while IFS='|' read -r service cost; do
    [ -z "$service" ] && continue
    existing="${PREVIOUS_COSTS[$service]:-0}"
    PREVIOUS_COSTS[$service]=$(echo "$existing + $cost" | bc -l)
done < <(echo "$PREVIOUS_RESULT" | jq -r '
    .ResultsByTime[].Groups[] |
    "\(.Keys[0])|\(.Metrics.UnblendedCost.Amount)"
')

# --- Compute Changes ---
# Collect all unique service names
declare -A ALL_SERVICES
for svc in "${!CURRENT_COSTS[@]}"; do ALL_SERVICES[$svc]=1; done
for svc in "${!PREVIOUS_COSTS[@]}"; do ALL_SERVICES[$svc]=1; done

declare -A COST_CHANGE
declare -A PCT_CHANGE
declare -A ALERT_LEVEL

for svc in "${!ALL_SERVICES[@]}"; do
    curr="${CURRENT_COSTS[$svc]:-0}"
    prev="${PREVIOUS_COSTS[$svc]:-0}"

    # Check if both are zero (or effectively zero)
    curr_is_zero=$(echo "$curr == 0" | bc -l)
    prev_is_zero=$(echo "$prev == 0" | bc -l)

    if [ "$curr_is_zero" -eq 1 ] && [ "$prev_is_zero" -eq 1 ]; then
        # Exclude services with zero cost in both periods
        continue
    fi

    dollar_change=$(echo "$curr - $prev" | bc -l)
    COST_CHANGE[$svc]="$dollar_change"

    if [ "$prev_is_zero" -eq 1 ] && [ "$curr_is_zero" -eq 0 ]; then
        # New service
        PCT_CHANGE[$svc]="NEW"
        ALERT_LEVEL[$svc]="High"
    elif [ "$curr_is_zero" -eq 1 ] && [ "$prev_is_zero" -eq 0 ]; then
        # Removed service
        PCT_CHANGE[$svc]="-100.00"
        ALERT_LEVEL[$svc]="Normal"
    else
        pct=$(echo "scale=2; ($curr - $prev) / $prev * 100" | bc -l)
        PCT_CHANGE[$svc]="$pct"

        # Assign alert level
        is_critical=$(echo "$pct > 50" | bc -l)
        is_high=$(echo "$pct > $COST_CHANGE_THRESHOLD" | bc -l)

        if [ "$is_critical" -eq 1 ]; then
            ALERT_LEVEL[$svc]="Critical"
        elif [ "$is_high" -eq 1 ]; then
            ALERT_LEVEL[$svc]="High"
        else
            ALERT_LEVEL[$svc]="Normal"
        fi
    fi
done

# --- Sort and Select Top Services ---
# Build sortable data: service|current_cost|pct_change_numeric
# For sorting by current cost desc -> top 10
# For sorting by pct increase desc -> top 5

# Top 10 by current cost (descending)
TOP_BY_COST=()
while IFS='|' read -r cost svc; do
    [ -z "$svc" ] && continue
    TOP_BY_COST+=("$svc")
done < <(
    for svc in "${!COST_CHANGE[@]}"; do
        curr="${CURRENT_COSTS[$svc]:-0}"
        printf "%s|%s\n" "$curr" "$svc"
    done | sort -t'|' -k1 -rn | head -10
)

# Top 5 by percentage increase (descending, NEW treated as very high)
TOP_BY_PCT=()
while IFS='|' read -r pct svc; do
    [ -z "$svc" ] && continue
    TOP_BY_PCT+=("$svc")
done < <(
    for svc in "${!PCT_CHANGE[@]}"; do
        pct_val="${PCT_CHANGE[$svc]}"
        if [ "$pct_val" = "NEW" ]; then
            # Treat NEW as a very large number for sorting
            printf "99999999|%s\n" "$svc"
        else
            printf "%s|%s\n" "$pct_val" "$svc"
        fi
    done | sort -t'|' -k1 -rn | head -5
)

# Union (no duplicates)
declare -A OUTPUT_SERVICES
for svc in "${TOP_BY_COST[@]}"; do OUTPUT_SERVICES[$svc]=1; done
for svc in "${TOP_BY_PCT[@]}"; do OUTPUT_SERVICES[$svc]=1; done

# --- Write CSV Output ---
mkdir -p "$(dirname "$OUTPUT_FILE")"
printf '"Service","Current Period Cost","Previous Period Cost","Change ($)","Change (%%)","Alert Level"\n' > "$OUTPUT_FILE"

for svc in "${!OUTPUT_SERVICES[@]}"; do
    curr=$(printf "%.2f" "${CURRENT_COSTS[$svc]:-0}")
    prev=$(printf "%.2f" "${PREVIOUS_COSTS[$svc]:-0}")
    change=$(printf "%.2f" "${COST_CHANGE[$svc]}")
    pct="${PCT_CHANGE[$svc]}"
    alert="${ALERT_LEVEL[$svc]}"

    # Format percentage: if numeric, format to 2 decimal places
    if [ "$pct" != "NEW" ] && [ "$pct" != "-100.00" ]; then
        pct=$(printf "%.2f" "$pct")
    fi

    printf '"%s","%.2f","%.2f","%.2f","%s","%s"\n' \
        "$svc" "$curr" "$prev" "$change" "$pct" "$alert" >> "$OUTPUT_FILE"
done

log "✅ DONE. Cost Trend report saved to: $OUTPUT_FILE"

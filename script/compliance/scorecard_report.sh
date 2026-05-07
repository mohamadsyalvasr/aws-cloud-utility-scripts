#!/bin/bash
# script/scorecard_report.sh
# Compliance Scorecard — Executive Summary Report
# Reads existing report CSVs from OUTPUT_DIR and produces a scorecard with
# infrastructure overview, cost optimization score, security posture,
# tagging compliance, resource lifecycle, and overall Health Score (0-100).
#
# This script makes NO AWS API calls. It only reads local CSV files.

set -euo pipefail

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Dependency Check ---
for cmd in awk bc; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Configuration ---
OUTPUT_DIR="${OUTPUT_DIR:-.}"
OUTPUT_FILE="scorecard_report.csv"

# --- Argument Parsing ---
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -f|--filename) shift; OUTPUT_FILE="$1" ;;
        -h|--help)
            echo "Usage: $0 [-f filename] [-h]"
            echo ""
            echo "  -f <filename>  Custom output filename (default: scorecard_report.csv)"
            echo "  -h             Show this help"
            echo ""
            echo "Environment:"
            echo "  OUTPUT_DIR     Directory containing report CSVs (default: current dir)"
            exit 0
            ;;
        *) ;; # Ignore unknown args (pass-through from framework)
    esac
    shift
done

# --- Validate OUTPUT_DIR ---
if [[ ! -d "$OUTPUT_DIR" ]]; then
    log "❌ OUTPUT_DIR does not exist: $OUTPUT_DIR"
    exit 1
fi

OUTPUT_PATH="${OUTPUT_DIR}/${OUTPUT_FILE}"

# --- Helper Functions ---

count_csv_rows() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi
    local lines
    lines=$(wc -l < "$file" | tr -d '[:space:]')
    if [[ "$lines" -le 1 ]]; then
        echo "0"
    else
        echo "$((lines - 1))"
    fi
}

write_row() {
    local section="$1"
    local metric="$2"
    local value="$3"
    local status="$4"
    echo "\"${section}\",\"${metric}\",\"${value}\",\"${status}\"" >> "$OUTPUT_PATH"
}

# --- Write CSV Header ---
echo '"Section","Metric","Value","Status"' > "$OUTPUT_PATH"

# --- Input CSV Discovery ---
log "📊 Scanning OUTPUT_DIR for report CSVs: $OUTPUT_DIR"

INVENTORY_CSVS=("aws_ec2_report.csv" "aws_rds_report.csv" "s3_report.csv" "lambda_report.csv" "ebs_report.csv" "elb_report.csv" "ecs_report.csv" "eks_report.csv")
FOUND_ANY=false

for csv in "${INVENTORY_CSVS[@]}"; do
    if [[ -f "${OUTPUT_DIR}/${csv}" ]]; then
        log "  ✅ Found: $csv"
        FOUND_ANY=true
    else
        log "  ⚠️  Missing: $csv"
    fi
done

# Check for opt_*.csv and sec_*.csv
OPT_COUNT=$(find "$OUTPUT_DIR" -maxdepth 1 -name "opt_*.csv" 2>/dev/null | wc -l | tr -d '[:space:]')
SEC_COUNT=$(find "$OUTPUT_DIR" -maxdepth 1 -name "sec_*.csv" 2>/dev/null | wc -l | tr -d '[:space:]')
log "  📈 Optimization CSVs found: $OPT_COUNT"
log "  🔒 Security CSVs found: $SEC_COUNT"

if [[ -f "${OUTPUT_DIR}/tagging_compliance_report.csv" ]]; then
    log "  ✅ Found: tagging_compliance_report.csv"
    FOUND_ANY=true
fi
if [[ -f "${OUTPUT_DIR}/resource_lifecycle_report.csv" ]]; then
    log "  ✅ Found: resource_lifecycle_report.csv"
    FOUND_ANY=true
fi

# Edge case: no input CSVs at all
if [[ "$FOUND_ANY" == "false" && "$OPT_COUNT" -eq 0 && "$SEC_COUNT" -eq 0 ]]; then
    write_row "Overall" "Health Score" "N/A - No report data available" "Critical"
    log "❌ No report CSVs found. Wrote N/A scorecard."
    exit 0
fi

# --- Tracking Variables ---
TOTAL_RESOURCE_COUNT=0
CRITICAL_FINDINGS=0
HIGH_FINDINGS=0
TOTAL_RECOMMENDATIONS=0
TAGGING_COMPLIANCE_PCT=0
TAGGING_AVAILABLE=false

# =============================================================================
# Section 1: Infrastructure Overview
# =============================================================================
log "📋 Aggregating infrastructure overview..."

aggregate_infrastructure() {
    local resource_names=("EC2 Instances" "RDS Instances" "S3 Buckets" "Lambda Functions" "EBS Volumes" "Load Balancers" "ECS Services" "EKS Clusters")
    local idx=0

    for csv in "${INVENTORY_CSVS[@]}"; do
        local count
        count=$(count_csv_rows "${OUTPUT_DIR}/${csv}")
        TOTAL_RESOURCE_COUNT=$((TOTAL_RESOURCE_COUNT + count))
        write_row "Infrastructure Overview" "${resource_names[$idx]}" "$count" "Good"
        idx=$((idx + 1))
    done
}

aggregate_infrastructure

# =============================================================================
# Section 2: Cost Optimization Score
# =============================================================================
log "💰 Aggregating cost optimization data..."

aggregate_optimization() {
    local opt_files
    opt_files=$(find "$OUTPUT_DIR" -maxdepth 1 -name "opt_*.csv" 2>/dev/null | sort)

    if [[ -z "$opt_files" ]]; then
        write_row "Cost Optimization Score" "Status" "No optimization data available" "Good"
        return
    fi

    local total_savings=0
    TOTAL_RECOMMENDATIONS=0
    local -a savings_list=()

    while IFS= read -r opt_file; do
        [[ -z "$opt_file" ]] && continue

        # Count recommendations (data rows)
        local row_count
        row_count=$(count_csv_rows "$opt_file")
        TOTAL_RECOMMENDATIONS=$((TOTAL_RECOMMENDATIONS + row_count))

        # Find savings column (look for column with "Saving" or "saving" in header)
        local header
        header=$(head -1 "$opt_file" 2>/dev/null || echo "")
        [[ -z "$header" ]] && continue

        local savings_col=0
        local col_idx=1
        IFS=',' read -ra hdr_fields <<< "$header"
        for field in "${hdr_fields[@]}"; do
            local clean_field
            clean_field=$(echo "$field" | tr -d '"' | tr '[:upper:]' '[:lower:]')
            if [[ "$clean_field" == *"saving"* || "$clean_field" == *"potential"* || "$clean_field" == *"monthly"* ]]; then
                savings_col=$col_idx
                break
            fi
            col_idx=$((col_idx + 1))
        done

        if [[ $savings_col -gt 0 ]]; then
            # Sum savings from this file
            local file_savings
            file_savings=$(awk -F',' -v col="$savings_col" 'NR>1 {
                val=$col
                gsub(/[" $,]/, "", val)
                if (val ~ /^[0-9.]+$/) sum += val
            } END { printf "%.2f", sum }' "$opt_file")
            total_savings=$(echo "$total_savings + $file_savings" | bc 2>/dev/null || echo "$total_savings")

            # Collect individual savings for top-3
            if [[ $savings_col -gt 0 ]]; then
                while IFS= read -r val; do
                    [[ -n "$val" && "$val" != "0" && "$val" != "0.00" ]] && savings_list+=("$val")
                done < <(awk -F',' -v col="$savings_col" 'NR>1 {
                    val=$col; gsub(/[" $,]/, "", val)
                    if (val ~ /^[0-9.]+$/ && val+0 > 0) print val
                }' "$opt_file")
            fi
        fi
    done <<< "$opt_files"

    # Determine status for total savings
    local savings_status="Good"
    local savings_int
    savings_int=$(echo "$total_savings" | awk '{printf "%d", $1}')
    if [[ $savings_int -gt 10000 ]]; then
        savings_status="Critical"
    elif [[ $savings_int -gt 1000 ]]; then
        savings_status="Warning"
    fi

    write_row "Cost Optimization Score" "Total Potential Savings" "\$${total_savings}/month" "$savings_status"
    write_row "Cost Optimization Score" "Total Recommendations" "$TOTAL_RECOMMENDATIONS" "Good"

    # Top 3 savings opportunities
    if [[ ${#savings_list[@]} -gt 0 ]]; then
        local sorted_savings
        sorted_savings=$(printf '%s\n' "${savings_list[@]}" | sort -rn | head -3)
        local rank=1
        while IFS= read -r sval; do
            [[ -z "$sval" ]] && continue
            write_row "Cost Optimization Score" "Top Opportunity #${rank}" "\$${sval}/month" "Warning"
            rank=$((rank + 1))
        done <<< "$sorted_savings"
    fi
}

aggregate_optimization

# =============================================================================
# Section 3: Security Posture Score
# =============================================================================
log "🔒 Aggregating security posture..."

aggregate_security() {
    local sec_files
    sec_files=$(find "$OUTPUT_DIR" -maxdepth 1 -name "sec_*.csv" 2>/dev/null | sort)

    if [[ -z "$sec_files" ]]; then
        write_row "Security Posture Score" "Status" "No security data available" "Good"
        return
    fi

    CRITICAL_FINDINGS=0
    HIGH_FINDINGS=0
    local medium_findings=0
    local low_findings=0

    while IFS= read -r sec_file; do
        [[ -z "$sec_file" ]] && continue

        # Find severity column
        local header
        header=$(head -1 "$sec_file" 2>/dev/null || echo "")
        [[ -z "$header" ]] && continue

        local sev_col=0
        local col_idx=1
        IFS=',' read -ra hdr_fields <<< "$header"
        for field in "${hdr_fields[@]}"; do
            local clean_field
            clean_field=$(echo "$field" | tr -d '"' | tr '[:upper:]' '[:lower:]')
            if [[ "$clean_field" == *"severity"* || "$clean_field" == *"risk"* || "$clean_field" == *"level"* ]]; then
                sev_col=$col_idx
                break
            fi
            col_idx=$((col_idx + 1))
        done

        if [[ $sev_col -gt 0 ]]; then
            # Count by severity
            while IFS= read -r sev_line; do
                local sev_lower
                sev_lower=$(echo "$sev_line" | tr -d '"' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
                case "$sev_lower" in
                    critical*) CRITICAL_FINDINGS=$((CRITICAL_FINDINGS + 1)) ;;
                    high*)     HIGH_FINDINGS=$((HIGH_FINDINGS + 1)) ;;
                    medium*)   medium_findings=$((medium_findings + 1)) ;;
                    low*)      low_findings=$((low_findings + 1)) ;;
                esac
            done < <(awk -F',' -v col="$sev_col" 'NR>1 { print $col }' "$sec_file")
        else
            # No severity column — count all rows as medium
            local row_count
            row_count=$(count_csv_rows "$sec_file")
            medium_findings=$((medium_findings + row_count))
        fi
    done <<< "$sec_files"

    # Determine status
    local sec_status="Good"
    if [[ $CRITICAL_FINDINGS -gt 0 ]]; then
        sec_status="Critical"
    elif [[ $HIGH_FINDINGS -gt 0 ]]; then
        sec_status="Warning"
    fi

    write_row "Security Posture Score" "Critical Findings" "$CRITICAL_FINDINGS" "$( [[ $CRITICAL_FINDINGS -gt 0 ]] && echo "Critical" || echo "Good" )"
    write_row "Security Posture Score" "High Findings" "$HIGH_FINDINGS" "$( [[ $HIGH_FINDINGS -gt 0 ]] && echo "Warning" || echo "Good" )"
    write_row "Security Posture Score" "Medium Findings" "$medium_findings" "Good"
    write_row "Security Posture Score" "Low Findings" "$low_findings" "Good"

    # Top 3 critical findings
    if [[ $CRITICAL_FINDINGS -gt 0 ]]; then
        local rank=1
        while IFS= read -r sec_file; do
            [[ -z "$sec_file" ]] && continue
            [[ $rank -gt 3 ]] && break

            local header
            header=$(head -1 "$sec_file" 2>/dev/null || echo "")
            local sev_col=0
            local col_idx=1
            IFS=',' read -ra hdr_fields <<< "$header"
            for field in "${hdr_fields[@]}"; do
                local clean_field
                clean_field=$(echo "$field" | tr -d '"' | tr '[:upper:]' '[:lower:]')
                if [[ "$clean_field" == *"severity"* || "$clean_field" == *"risk"* || "$clean_field" == *"level"* ]]; then
                    sev_col=$col_idx
                    break
                fi
                col_idx=$((col_idx + 1))
            done

            if [[ $sev_col -gt 0 ]]; then
                while IFS= read -r finding_line; do
                    [[ $rank -gt 3 ]] && break
                    # Extract a description (use first few fields)
                    local desc
                    desc=$(echo "$finding_line" | awk -F',' '{gsub(/"/, "", $1); gsub(/"/, "", $2); print $1 " - " $2}' | head -c 80)
                    write_row "Security Posture Score" "Top Critical Finding $rank" "$desc" "Critical"
                    rank=$((rank + 1))
                done < <(awk -F',' -v col="$sev_col" 'NR>1 && tolower($col) ~ /critical/ { print $0 }' "$sec_file")
            fi
        done <<< "$sec_files"
    fi
}

aggregate_security

# =============================================================================
# Section 4: Tagging Compliance
# =============================================================================
log "🏷️  Aggregating tagging compliance..."

aggregate_tagging() {
    local tagging_file="${OUTPUT_DIR}/tagging_compliance_report.csv"

    if [[ ! -f "$tagging_file" ]]; then
        write_row "Tagging Compliance" "Overall Compliance" "N/A - Report not available" "Warning"
        return
    fi

    # Find compliance % column
    local header
    header=$(head -1 "$tagging_file")
    local comp_col=0
    local col_idx=1
    IFS=',' read -ra hdr_fields <<< "$header"
    for field in "${hdr_fields[@]}"; do
        local clean_field
        clean_field=$(echo "$field" | tr -d '"' | tr '[:upper:]' '[:lower:]')
        if [[ "$clean_field" == *"compliance"* || "$clean_field" == *"percent"* || "$clean_field" == *"%"* ]]; then
            comp_col=$col_idx
            break
        fi
        col_idx=$((col_idx + 1))
    done

    if [[ $comp_col -gt 0 ]]; then
        # Average compliance percentage
        TAGGING_COMPLIANCE_PCT=$(awk -F',' -v col="$comp_col" 'NR>1 {
            val=$col; gsub(/[" %]/, "", val)
            if (val ~ /^[0-9.]+$/) { sum += val; count++ }
        } END { if (count>0) printf "%.0f", sum/count; else print "0" }' "$tagging_file")
        TAGGING_AVAILABLE=true
    else
        TAGGING_COMPLIANCE_PCT=0
        TAGGING_AVAILABLE=true
    fi

    # Determine status
    local tag_status="Good"
    if [[ $TAGGING_COMPLIANCE_PCT -lt 50 ]]; then
        tag_status="Critical"
    elif [[ $TAGGING_COMPLIANCE_PCT -lt 80 ]]; then
        tag_status="Warning"
    fi

    write_row "Tagging Compliance" "Overall Compliance" "${TAGGING_COMPLIANCE_PCT}%" "$tag_status"
}

aggregate_tagging

# =============================================================================
# Section 5: Resource Lifecycle
# =============================================================================
log "♻️  Aggregating resource lifecycle..."

aggregate_lifecycle() {
    local lifecycle_file="${OUTPUT_DIR}/resource_lifecycle_report.csv"

    if [[ ! -f "$lifecycle_file" ]]; then
        write_row "Resource Lifecycle" "Outdated/Deprecated Resources" "N/A - Report not available" "Warning"
        return
    fi

    local outdated_count
    outdated_count=$(count_csv_rows "$lifecycle_file")

    # Determine status
    local lc_status="Good"
    if [[ $outdated_count -gt 20 ]]; then
        lc_status="Critical"
    elif [[ $outdated_count -ge 5 ]]; then
        lc_status="Warning"
    fi

    write_row "Resource Lifecycle" "Outdated/Deprecated Resources" "$outdated_count" "$lc_status"
}

aggregate_lifecycle

# =============================================================================
# Section 6: Health Score Calculation
# =============================================================================
log "🏥 Calculating Health Score..."

calculate_health_score() {
    local score=100

    # Deduction: -10 per Critical finding
    score=$(echo "$score - ($CRITICAL_FINDINGS * 10)" | bc)

    # Deduction: -5 per High finding
    score=$(echo "$score - ($HIGH_FINDINGS * 5)" | bc)

    # Deduction: -(recommendations/total_resources)*30, capped at 30
    if [[ $TOTAL_RESOURCE_COUNT -gt 0 && $TOTAL_RECOMMENDATIONS -gt 0 ]]; then
        local rec_deduction
        rec_deduction=$(echo "scale=2; ($TOTAL_RECOMMENDATIONS / $TOTAL_RESOURCE_COUNT) * 30" | bc)
        # Cap at 30
        local capped
        capped=$(echo "if ($rec_deduction > 30) 30 else $rec_deduction" | bc)
        score=$(echo "$score - $capped" | bc)
    fi

    # Deduction: -(100 - compliance_pct) * 0.2
    if [[ "$TAGGING_AVAILABLE" == "true" ]]; then
        local tag_deduction
        tag_deduction=$(echo "scale=2; (100 - $TAGGING_COMPLIANCE_PCT) * 0.2" | bc)
        score=$(echo "$score - $tag_deduction" | bc)
    fi

    # Enforce minimum of 0
    local score_int
    score_int=$(echo "$score" | awk '{printf "%d", $1}')
    if [[ $score_int -lt 0 ]]; then
        score_int=0
    fi

    # Determine status
    local health_status="Good"
    if [[ $score_int -lt 50 ]]; then
        health_status="Critical"
    elif [[ $score_int -lt 80 ]]; then
        health_status="Warning"
    fi

    write_row "Overall" "Health Score" "$score_int" "$health_status"

    log "✅ Health Score: $score_int ($health_status)"
}

calculate_health_score

# --- Done ---
log "✅ Scorecard written to: $OUTPUT_PATH"

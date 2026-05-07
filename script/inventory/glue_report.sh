#!/bin/bash
# glue_report.sh
# Gathers an inventory report on AWS Glue resources (Jobs, Crawlers, Databases).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_JOBS="${OUTPUT_DIR}/glue_jobs_report.csv"
OUTPUT_FILE_CRAWLERS="${OUTPUT_DIR}/glue_crawlers_report.csv"
OUTPUT_FILE_DATABASES="${OUTPUT_DIR}/glue_databases_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-h]
Options:
  -r <regions>     Comma-separated list of AWS regions. Default: ${REGIONS[*]}
  -h               Show this help message.

This script generates three CSV files:
  1. glue_jobs_report.csv      - Glue ETL Jobs
  2. glue_crawlers_report.csv  - Glue Crawlers
  3. glue_databases_report.csv - Glue Data Catalog Databases
EOF
    exit 1
}

while getopts "r:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

# --- Main Script ---
mkdir -p "$(dirname "$OUTPUT_FILE_JOBS")"

# =========================================================================
# PART 1: Glue Jobs
# =========================================================================
log "✍️ [Part 1] Generating Glue Jobs report..."
printf '"Job Name","Role","Glue Version","Worker Type","Max Workers","Timeout (min)","Last Modified","State","Region"\n' > "$OUTPUT_FILE_JOBS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Jobs)"

    JOBS_DATA=$(aws glue get-jobs --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Jobs":[]}')
    JOB_COUNT=$(echo "$JOBS_DATA" | jq '.Jobs | length')

    if [[ "$JOB_COUNT" -eq 0 ]]; then
        log "  [Glue Jobs] No jobs found."
    else
        log "  [Glue Jobs] Found $JOB_COUNT jobs."
        echo "$JOBS_DATA" | jq -c '.Jobs[]' | while read -r job; do
            JOB_NAME=$(echo "$job" | jq -r '.Name // "N/A"')
            ROLE=$(echo "$job" | jq -r '.Role // "N/A"' | awk -F/ '{print $NF}')
            GLUE_VERSION=$(echo "$job" | jq -r '.GlueVersion // "N/A"')
            WORKER_TYPE=$(echo "$job" | jq -r '.WorkerType // "N/A"')
            MAX_WORKERS=$(echo "$job" | jq -r '.NumberOfWorkers // "N/A"')
            TIMEOUT=$(echo "$job" | jq -r '.Timeout // "N/A"')
            LAST_MODIFIED=$(echo "$job" | jq -r '.LastModifiedOn // "N/A"')

            # Get last run state
            LAST_RUN=$(aws glue get-job-runs --region "$region" --job-name "$JOB_NAME" \
                --query "JobRuns[0].JobRunState" --output text --no-paginate 2>/dev/null || echo "N/A")
            if [[ -z "$LAST_RUN" || "$LAST_RUN" == "None" ]]; then
                LAST_RUN="NO_RUNS"
            fi

            printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                "$JOB_NAME" \
                "$ROLE" \
                "$GLUE_VERSION" \
                "$WORKER_TYPE" \
                "$MAX_WORKERS" \
                "$TIMEOUT" \
                "$LAST_MODIFIED" \
                "$LAST_RUN" \
                "$region" >> "$OUTPUT_FILE_JOBS"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done
log "✅ [Part 1] Glue Jobs report saved to: $OUTPUT_FILE_JOBS"

# =========================================================================
# PART 2: Glue Crawlers
# =========================================================================
log "✍️ [Part 2] Generating Glue Crawlers report..."
printf '"Crawler Name","Database Name","State","Schedule","Last Run Status","Last Run Time","Region"\n' > "$OUTPUT_FILE_CRAWLERS"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Crawlers)"

    CRAWLERS_DATA=$(aws glue get-crawlers --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Crawlers":[]}')
    CRAWLER_COUNT=$(echo "$CRAWLERS_DATA" | jq '.Crawlers | length')

    if [[ "$CRAWLER_COUNT" -eq 0 ]]; then
        log "  [Glue Crawlers] No crawlers found."
    else
        log "  [Glue Crawlers] Found $CRAWLER_COUNT crawlers."
        echo "$CRAWLERS_DATA" | jq -c '.Crawlers[]' | while read -r crawler; do
            CRAWLER_NAME=$(echo "$crawler" | jq -r '.Name // "N/A"')
            DB_NAME=$(echo "$crawler" | jq -r '.DatabaseName // "N/A"')
            STATE=$(echo "$crawler" | jq -r '.State // "N/A"')
            SCHEDULE=$(echo "$crawler" | jq -r '.Schedule.ScheduleExpression // "N/A"')
            LAST_STATUS=$(echo "$crawler" | jq -r '.LastCrawl.Status // "N/A"')
            LAST_TIME=$(echo "$crawler" | jq -r '.LastCrawl.StartTime // "N/A"')

            printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
                "$CRAWLER_NAME" \
                "$DB_NAME" \
                "$STATE" \
                "$SCHEDULE" \
                "$LAST_STATUS" \
                "$LAST_TIME" \
                "$region" >> "$OUTPUT_FILE_CRAWLERS"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done
log "✅ [Part 2] Glue Crawlers report saved to: $OUTPUT_FILE_CRAWLERS"

# =========================================================================
# PART 3: Glue Databases (Data Catalog)
# =========================================================================
log "✍️ [Part 3] Generating Glue Databases report..."
printf '"Database Name","Description","Location URI","Created","Region"\n' > "$OUTPUT_FILE_DATABASES"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m (Databases)"

    DBS_DATA=$(aws glue get-databases --region "$region" --output json --no-paginate 2>/dev/null || echo '{"DatabaseList":[]}')
    DB_COUNT=$(echo "$DBS_DATA" | jq '.DatabaseList | length')

    if [[ "$DB_COUNT" -eq 0 ]]; then
        log "  [Glue Databases] No databases found."
    else
        log "  [Glue Databases] Found $DB_COUNT databases."
        echo "$DBS_DATA" | jq -c '.DatabaseList[]' | while read -r db; do
            DB_NAME=$(echo "$db" | jq -r '.Name // "N/A"')
            DESCRIPTION=$(echo "$db" | jq -r '.Description // "N/A"' | sed 's/"/""/g')
            LOCATION=$(echo "$db" | jq -r '.LocationUri // "N/A"')
            CREATED=$(echo "$db" | jq -r '.CreateTime // "N/A"')

            printf '"%s","%s","%s","%s","%s"\n' \
                "$DB_NAME" \
                "$DESCRIPTION" \
                "$LOCATION" \
                "$CREATED" \
                "$region" >> "$OUTPUT_FILE_DATABASES"
        done
    fi
    log "Region \033[1;33m$region\033[0m Complete."
done
log "✅ [Part 3] Glue Databases report saved to: $OUTPUT_FILE_DATABASES"
log "✅ DONE. All Glue reports generated."

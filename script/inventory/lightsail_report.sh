#!/bin/bash
# lightsail_report.sh
# Gathers a report on Amazon Lightsail resources (Instances, Databases, Load Balancers, Container Services).

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/lightsail_report.csv"

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]
EOF
    exit 1
}

while getopts "r:f:h" opt; do
    case "$opt" in
        r) IFS=',' read -r -a REGIONS <<< "$OPTARG" ;;
        f) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

# --- Dependency Check ---
for cmd in aws jq; do
    if ! command -v "$cmd" &>/dev/null; then
        log "❌ Required command not found: $cmd"
        exit 1
    fi
done

# --- Main ---
log "✍️ Preparing output file: $OUTPUT_FILE"
mkdir -p "$(dirname "$OUTPUT_FILE")"

printf '"Resource Type","Name","State","Blueprint/Plan","RAM (GB)","vCPUs","Monthly Cost (USD)","Region"\n' > "$OUTPUT_FILE"

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # --- Lightsail Instances ---
    INSTANCES=$(aws lightsail get-instances --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$INSTANCES" && "$(echo "$INSTANCES" | jq '.instances | length')" -gt 0 ]]; then
        echo "$INSTANCES" | jq -r --arg r "$region" '.instances[] | [
            "Instance",
            .name,
            (.state.name // "N/A"),
            (.blueprintId // "N/A"),
            ((.hardware.ramSizeInGb // 0) | tostring),
            ((.hardware.cpuCount // 0) | tostring),
            ((.networking.monthlyTransfer.gbPerMonthAllocated // 0) | tostring),
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Instances] No instances found."
    fi

    # --- Lightsail Databases ---
    DATABASES=$(aws lightsail get-relational-databases --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$DATABASES" && "$(echo "$DATABASES" | jq '.relationalDatabases | length')" -gt 0 ]]; then
        echo "$DATABASES" | jq -r --arg r "$region" '.relationalDatabases[] | [
            "Database",
            .name,
            (.state // "N/A"),
            (.engine // "N/A"),
            ((.hardware.ramSizeInGb // 0) | tostring),
            ((.hardware.cpuCount // 0) | tostring),
            "N/A",
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Databases] No databases found."
    fi

    # --- Lightsail Load Balancers ---
    LOAD_BALANCERS=$(aws lightsail get-load-balancers --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$LOAD_BALANCERS" && "$(echo "$LOAD_BALANCERS" | jq '.loadBalancers | length')" -gt 0 ]]; then
        echo "$LOAD_BALANCERS" | jq -r --arg r "$region" '.loadBalancers[] | [
            "Load Balancer",
            .name,
            (.state // "N/A"),
            "Standard",
            "N/A",
            "N/A",
            "18",
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Load Balancers] No load balancers found."
    fi

    # --- Lightsail Container Services ---
    CONTAINERS=$(aws lightsail get-container-services --region "$region" --output json --no-paginate 2>/dev/null || true)

    if [[ -n "$CONTAINERS" && "$(echo "$CONTAINERS" | jq '.containerServices | length')" -gt 0 ]]; then
        echo "$CONTAINERS" | jq -r --arg r "$region" '.containerServices[] | [
            "Container Service",
            .containerServiceName,
            (.state // "N/A"),
            (.power // "N/A"),
            "N/A",
            ((.scale // 0) | tostring),
            "N/A",
            $r
        ] | @csv' >> "$OUTPUT_FILE"
    else
        log "  [Container Services] No container services found."
    fi

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Report saved to: $OUTPUT_FILE"

#!/bin/bash
# eks_report.sh
# Gathers a report on all EKS clusters and saves it to a dated output directory.

set -euo pipefail

# --- Configuration and Arguments ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="output/${YEAR}/${MONTH}/${DAY}"
OUTPUT_FILE="${OUTPUT_DIR}/eks_report_$(date +"%Y%m%d-%H%M%S").csv"

# --- Logging Function ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage function ---
usage() {
    cat <<EOF >&2
Usage: $0 [-r regions] [-f filename] [-h]

Options:
  -r <regions>     Comma-separated list of AWS regions (e.g., "ap-southeast-1,us-east-1").
                   Default: ${REGIONS[@]}
  -f <filename>    Custom filename for the output CSV file.
                   Default: eks_report_<timestamp>.csv
  -h               Show this help message.
EOF
    exit 1
}

# --- Dependency Check ---
check_dependencies() {
    log "🔎 Checking dependencies (aws cli, jq)..."
    if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log "❌ Dependencies not met. Please install AWS CLI and jq."
        exit 1
    fi
    log "✅ Dependencies met."
}

# --- Main Script Logic ---
main() {
    check_dependencies
    
    while getopts "r:f:h" opt; do
        case "$opt" in
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

    log "✍️ Preparing output file: $OUTPUT_FILE"
    mkdir -p "$(dirname "$OUTPUT_FILE")"

    # Create CSV header with the requested columns
    printf '"Name","Status","Kubernetes version","Support period","Upgrade policy","Date Created","Provider","Region"\n' > "$OUTPUT_FILE"

    for region in "${REGIONS[@]}"; do
        log "Processing Region: \033[1;33m$region\033[0m"

        local eks_clusters=$(aws eks list-clusters --region "$region" --query 'clusters' --output json)
        
        if [[ "$(echo "$eks_clusters" | jq 'length')" -gt 0 ]]; then
            echo "$eks_clusters" | jq -c '.[]' | while read -r cluster_name; do
                # jq -r already unquotes the string, no need for `tr -d '"'`
                local cluster_name_clean="${cluster_name}"
                
                local cluster_details=$(aws eks describe-cluster --region "$region" --name "$cluster_name_clean" --output json)

                local name=$(echo "$cluster_details" | jq -r '.cluster.name')
                local status=$(echo "$cluster_details" | jq -r '.cluster.status')
                local k8s_version=$(echo "$cluster_details" | jq -r '.cluster.version')
                local created_date=$(echo "$cluster_details" | jq -r '.cluster.createdAt')
                
                # These fields are not directly available from the EKS API and would require more complex logic or manual lookup.
                local support_period="N/A"
                local upgrade_policy="N/A"
                local provider="N/A"

                printf '"%s","%s","%s","%s","%s","%s","%s","%s"\n' \
                    "$name" \
                    "$status" \
                    "$k8s_version" \
                    "$support_period" \
                    "$upgrade_policy" \
                    "$created_date" \
                    "$provider" \
                    "$region" >> "$OUTPUT_FILE"
            done
        else
            log "  [EKS] No clusters found."
        fi

        log "Region \033[1;33m$region\033[0m Complete."
    done

    log "✅ DONE. Report saved to: $OUTPUT_FILE"
}

main "$@"
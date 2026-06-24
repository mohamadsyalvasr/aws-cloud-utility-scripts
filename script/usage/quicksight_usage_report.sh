#!/bin/bash
# quicksight_usage_report.sh
# Gathers a usage report on Amazon QuickSight: user sessions and cost.
# Uses two approaches:
#   1. Cost Explorer - QuickSight cost breakdown (always available)
#   2. QuickSight API - List users and their roles/status
#
# NOTE: QuickSight is a regional service but user management is per-account.
#       The default region for QuickSight is usually us-east-1.

set -euo pipefail

# --- Configuration ---
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE_COST="${OUTPUT_DIR}/quicksight_cost_report.csv"
OUTPUT_FILE_USERS="${OUTPUT_DIR}/quicksight_users_report.csv"
START_DATE=""
END_DATE=""
QS_REGION="us-east-1"  # QuickSight identity region (usually us-east-1)

# --- Logging ---
log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] $*"
}

# --- Usage ---
usage() {
    cat <<EOF >&2
Usage: $0 -b <start_date> -e <end_date> [-r qs_region] [-h]

Options:
  -b <start_date>  REQUIRED: Start date (YYYY-MM-DD).
  -e <end_date>    REQUIRED: End date (YYYY-MM-DD).
  -r <qs_region>   QuickSight identity region. Default: us-east-1
  -h               Show this help message.

NOTE: QuickSight user management is typically in us-east-1 regardless of
      where dashboards are deployed.
EOF
    exit 1
}

while getopts "b:e:r:h" opt; do
    case "$opt" in
        b) START_DATE="$OPTARG" ;;
        e) END_DATE="$OPTARG" ;;
        r) QS_REGION="$OPTARG" ;;
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
if ! command -v aws >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    log "❌ Dependencies not met. Please install AWS CLI and jq."; exit 1
fi

mkdir -p "$(dirname "$OUTPUT_FILE_COST")"

# Get AWS Account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text 2>/dev/null || echo "unknown")

# =========================================================================
# PART 1: QuickSight Cost from Cost Explorer (Global, always available)
# =========================================================================
log "✍️ [Part 1] Generating QuickSight cost breakdown..."
printf '"Usage Type","Cost (USD)","Unit","Period"\n' > "$OUTPUT_FILE_COST"

COST_DATA=$(aws ce get-cost-and-usage \
    --time-period Start="$START_DATE",End="$END_DATE" \
    --metrics "BlendedCost" "UsageQuantity" \
    --granularity "MONTHLY" \
    --filter '{
        "Dimensions": {
            "Key": "SERVICE",
            "Values": ["Amazon QuickSight"]
        }
    }' \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json 2>/dev/null || echo '{"ResultsByTime":[]}')

RESULTS_COUNT=$(echo "$COST_DATA" | jq '[.ResultsByTime[].Groups[]] | length')

if [[ "$RESULTS_COUNT" -gt 0 ]]; then
    echo "$COST_DATA" | jq -r --arg period "${START_DATE} to ${END_DATE}" '
        .ResultsByTime[].Groups[] |
        [
            .Keys[0],
            .Metrics.BlendedCost.Amount,
            .Metrics.BlendedCost.Unit,
            $period
        ] | @csv
    ' >> "$OUTPUT_FILE_COST"
    log "  ✅ QuickSight cost data written ($RESULTS_COUNT usage types)."
else
    log "  ⚠️ No QuickSight cost data found for this period."
fi

log "✅ [Part 1] Cost report saved to: $OUTPUT_FILE_COST"

# =========================================================================
# PART 2: QuickSight Users Inventory
# =========================================================================
log "✍️ [Part 2] Generating QuickSight users report..."
printf '"Username","Email","Role","Identity Type","Active","Principal ID","Region"\n' > "$OUTPUT_FILE_USERS"

log "  [QuickSight] Listing users in account $ACCOUNT_ID (region: $QS_REGION)..."

# List QuickSight users - try default namespace
USERS_DATA=$(aws quicksight list-users \
    --aws-account-id "$ACCOUNT_ID" \
    --namespace default \
    --region "$QS_REGION" \
    --output json --no-paginate 2>/dev/null || echo '{"UserList":[]}')

USER_COUNT=$(echo "$USERS_DATA" | jq '.UserList | length')

if [[ "$USER_COUNT" -eq 0 ]]; then
    log "  [QuickSight] No users found (or QuickSight not active in this account)."
else
    log "  [QuickSight] Found $USER_COUNT users."
    echo "$USERS_DATA" | jq -c '.UserList[]' | while read -r user; do
        USERNAME=$(echo "$user" | jq -r '.UserName // "N/A"')
        EMAIL=$(echo "$user" | jq -r '.Email // "N/A"')
        ROLE=$(echo "$user" | jq -r '.Role // "N/A"')
        IDENTITY_TYPE=$(echo "$user" | jq -r '.IdentityType // "N/A"')
        ACTIVE=$(echo "$user" | jq -r '.Active // "N/A"')
        PRINCIPAL_ID=$(echo "$user" | jq -r '.PrincipalId // "N/A"')

        printf '"%s","%s","%s","%s","%s","%s","%s"\n' \
            "$USERNAME" \
            "$EMAIL" \
            "$ROLE" \
            "$IDENTITY_TYPE" \
            "$ACTIVE" \
            "$PRINCIPAL_ID" \
            "$QS_REGION" >> "$OUTPUT_FILE_USERS"
    done
fi

log "✅ [Part 2] Users report saved to: $OUTPUT_FILE_USERS"
log "✅ DONE. QuickSight usage reports generated."

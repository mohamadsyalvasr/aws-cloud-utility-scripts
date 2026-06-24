#!/bin/bash
# serverless_topology.sh
# Discovers serverless architecture: Lambda, API Gateway, SQS, SNS, DynamoDB,
# EventBridge, Step Functions and their event source relationships.
# Outputs a Mermaid diagram.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/architecture_serverless_topology.md"

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

# --- Main ---
log "✍️ Generating serverless topology diagram..."
mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<'HEADER'
# Serverless Architecture Topology

Auto-generated diagram showing Lambda functions, their triggers (event sources),
and downstream service connections.

HEADER

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all Lambda functions
    FUNCTIONS=$(aws lambda list-functions --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Functions":[]}')
    FUNC_COUNT=$(echo "$FUNCTIONS" | jq '.Functions | length')

    if [[ "$FUNC_COUNT" -eq 0 ]]; then
        log "  No Lambda functions found in $region."
        continue
    fi

    log "  Found $FUNC_COUNT Lambda functions. Discovering connections..."

    echo "" >> "$OUTPUT_FILE"
    echo "## Region: $region" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
    echo '```mermaid' >> "$OUTPUT_FILE"
    echo "graph LR" >> "$OUTPUT_FILE"
    echo "    %% Serverless topology for $region" >> "$OUTPUT_FILE"

    # Track unique nodes to avoid duplicates
    declare -A NODES_WRITTEN=()

    echo "$FUNCTIONS" | jq -c '.Functions[]' | while read -r func; do
        FUNC_NAME=$(echo "$func" | jq -r '.FunctionName')
        FUNC_ARN=$(echo "$func" | jq -r '.FunctionArn')
        RUNTIME=$(echo "$func" | jq -r '.Runtime // "N/A"')
        FUNC_NODE="LAMBDA_${FUNC_NAME//[-.]/_}"

        echo "    ${FUNC_NODE}[\"⚡ $FUNC_NAME<br/>$RUNTIME\"]" >> "$OUTPUT_FILE"

        # --- Discover Event Source Mappings (SQS, Kinesis, DynamoDB Streams) ---
        EVENT_SOURCES=$(aws lambda list-event-source-mappings --region "$region" \
            --function-name "$FUNC_NAME" --output json 2>/dev/null || echo '{"EventSourceMappings":[]}')

        echo "$EVENT_SOURCES" | jq -c '.EventSourceMappings[]?' | while read -r esm; do
            SOURCE_ARN=$(echo "$esm" | jq -r '.EventSourceArn // ""')

            if [[ "$SOURCE_ARN" == *":sqs:"* ]]; then
                QUEUE_NAME=$(echo "$SOURCE_ARN" | awk -F: '{print $NF}')
                SRC_NODE="SQS_${QUEUE_NAME//[-.]/_}"
                echo "    ${SRC_NODE}[\"📨 SQS: $QUEUE_NAME\"] --> ${FUNC_NODE}" >> "$OUTPUT_FILE"

            elif [[ "$SOURCE_ARN" == *":kinesis:"* ]]; then
                STREAM_NAME=$(echo "$SOURCE_ARN" | awk -F'/' '{print $NF}')
                SRC_NODE="KINESIS_${STREAM_NAME//[-.]/_}"
                echo "    ${SRC_NODE}[\"🌊 Kinesis: $STREAM_NAME\"] --> ${FUNC_NODE}" >> "$OUTPUT_FILE"

            elif [[ "$SOURCE_ARN" == *":dynamodb:"* ]]; then
                TABLE_NAME=$(echo "$SOURCE_ARN" | awk -F'/' '{print $2}')
                SRC_NODE="DDB_${TABLE_NAME//[-.]/_}"
                echo "    ${SRC_NODE}[(\"📊 DynamoDB: $TABLE_NAME\")] --> ${FUNC_NODE}" >> "$OUTPUT_FILE"
            fi
        done

        # --- Discover SNS Subscriptions targeting this Lambda ---
        # (Check if any SNS topic has this Lambda as subscriber)
        SNS_SUBS=$(aws sns list-subscriptions-by-topic --region "$region" 2>/dev/null | \
            jq -r --arg arn "$FUNC_ARN" '.Subscriptions[]? | select(.Endpoint == $arn) | .TopicArn' 2>/dev/null || echo "")

        # Alternative: list all subscriptions and filter
        if [[ -z "$SNS_SUBS" ]]; then
            SNS_SUBS=$(aws sns list-subscriptions --region "$region" --output json --no-paginate 2>/dev/null | \
                jq -r --arg arn "$FUNC_ARN" '.Subscriptions[]? | select(.Endpoint == $arn and .Protocol == "lambda") | .TopicArn' 2>/dev/null || echo "")
        fi

        for topic_arn in $SNS_SUBS; do
            if [[ -n "$topic_arn" ]]; then
                TOPIC_NAME=$(echo "$topic_arn" | awk -F: '{print $NF}')
                SRC_NODE="SNS_${TOPIC_NAME//[-.]/_}"
                echo "    ${SRC_NODE}[\"📢 SNS: $TOPIC_NAME\"] --> ${FUNC_NODE}" >> "$OUTPUT_FILE"
            fi
        done

        # --- Check if Lambda is in a VPC (connects to RDS/ElastiCache) ---
        VPC_ID=$(echo "$func" | jq -r '.VpcConfig.VpcId // ""')
        if [[ -n "$VPC_ID" && "$VPC_ID" != "null" ]]; then
            echo "    ${FUNC_NODE} -.->|VPC| VPC_${VPC_ID//[-.]/_}[\"🔒 VPC: $VPC_ID\"]" >> "$OUTPUT_FILE"
        fi

    done

    # --- API Gateway → Lambda connections ---
    log "  Discovering API Gateway integrations..."

    # REST APIs (v1)
    REST_APIS=$(aws apigateway get-rest-apis --region "$region" --output json --no-paginate 2>/dev/null || echo '{"items":[]}')
    echo "$REST_APIS" | jq -c '.items[]?' | while read -r api; do
        API_ID=$(echo "$api" | jq -r '.id')
        API_NAME=$(echo "$api" | jq -r '.name')
        API_NODE="APIGW_${API_ID//[-.]/_}"

        # Get resources and check for Lambda integrations
        RESOURCES=$(aws apigateway get-resources --region "$region" --rest-api-id "$API_ID" \
            --output json --no-paginate 2>/dev/null || echo '{"items":[]}')

        HAS_LAMBDA=false
        LAMBDA_TARGETS=""
        echo "$RESOURCES" | jq -c '.items[]?' | while read -r resource; do
            RESOURCE_ID=$(echo "$resource" | jq -r '.id')
            METHODS=$(echo "$resource" | jq -r '.resourceMethods // {} | keys[]' 2>/dev/null || echo "")

            for method in $METHODS; do
                INTEGRATION=$(aws apigateway get-integration --region "$region" \
                    --rest-api-id "$API_ID" --resource-id "$RESOURCE_ID" --http-method "$method" \
                    --output json 2>/dev/null || echo '{}')

                INT_URI=$(echo "$INTEGRATION" | jq -r '.uri // ""')
                if [[ "$INT_URI" == *"lambda"* ]]; then
                    # Extract function name from URI
                    LAMBDA_FUNC=$(echo "$INT_URI" | grep -oP 'function:\K[^/]+' || echo "")
                    if [[ -n "$LAMBDA_FUNC" ]]; then
                        LAMBDA_NODE="LAMBDA_${LAMBDA_FUNC//[-.]/_}"
                        echo "    ${API_NODE}[\"🌐 API: $API_NAME\"] --> ${LAMBDA_NODE}" >> "$OUTPUT_FILE"
                    fi
                fi
            done
        done
    done

    # HTTP APIs (v2)
    HTTP_APIS=$(aws apigatewayv2 get-apis --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Items":[]}')
    echo "$HTTP_APIS" | jq -c '.Items[]?' | while read -r api; do
        API_ID=$(echo "$api" | jq -r '.ApiId')
        API_NAME=$(echo "$api" | jq -r '.Name')
        API_NODE="APIGW2_${API_ID//[-.]/_}"

        INTEGRATIONS=$(aws apigatewayv2 get-integrations --region "$region" --api-id "$API_ID" \
            --output json 2>/dev/null || echo '{"Items":[]}')

        echo "$INTEGRATIONS" | jq -c '.Items[]?' | while read -r integ; do
            INT_URI=$(echo "$integ" | jq -r '.IntegrationUri // ""')
            if [[ "$INT_URI" == *"lambda"* || "$INT_URI" == arn:*:lambda:* ]]; then
                LAMBDA_FUNC=$(echo "$INT_URI" | awk -F: '{print $NF}' | awk -F/ '{print $NF}')
                if [[ -n "$LAMBDA_FUNC" ]]; then
                    LAMBDA_NODE="LAMBDA_${LAMBDA_FUNC//[-.]/_}"
                    echo "    ${API_NODE}[\"🌐 HTTP API: $API_NAME\"] --> ${LAMBDA_NODE}" >> "$OUTPUT_FILE"
                fi
            fi
        done
    done

    # --- Step Functions ---
    log "  Discovering Step Functions..."
    SFN_MACHINES=$(aws stepfunctions list-state-machines --region "$region" --output json --no-paginate 2>/dev/null || echo '{"stateMachines":[]}')
    echo "$SFN_MACHINES" | jq -c '.stateMachines[]?' | while read -r sfn; do
        SFN_NAME=$(echo "$sfn" | jq -r '.name')
        SFN_NODE="SFN_${SFN_NAME//[-.]/_}"
        echo "    ${SFN_NODE}[\"🔄 StepFn: $SFN_NAME\"]" >> "$OUTPUT_FILE"
    done

    echo '```' >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    # Clean up associative array for next region
    unset NODES_WRITTEN
    declare -A NODES_WRITTEN=()

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Serverless topology saved to: $OUTPUT_FILE"

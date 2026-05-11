#!/bin/bash
# vpc_topology.sh
# Discovers VPC-centric architecture: EC2, RDS, ELB, NAT, Subnets, Security Groups
# and their relationships. Outputs a Mermaid diagram.

set -euo pipefail

# --- Configuration ---
REGIONS=("ap-southeast-1" "ap-southeast-3")
YEAR=$(date +"%Y")
MONTH=$(date +"%m")
DAY=$(date +"%d")
OUTPUT_DIR="${OUTPUT_DIR:-export/aws-cloud-report-${YEAR}-${MONTH}-${DAY}}"
OUTPUT_FILE="${OUTPUT_DIR}/architecture_vpc_topology.md"

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
log "✍️ Generating VPC topology diagram..."
mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<'HEADER'
# VPC Architecture Topology

Auto-generated architecture diagram based on live AWS infrastructure.

HEADER

for region in "${REGIONS[@]}"; do
    log "Processing Region: \033[1;33m$region\033[0m"

    # Get all VPCs
    VPCS=$(aws ec2 describe-vpcs --region "$region" --output json --no-paginate 2>/dev/null || echo '{"Vpcs":[]}')
    VPC_COUNT=$(echo "$VPCS" | jq '.Vpcs | length')

    if [[ "$VPC_COUNT" -eq 0 ]]; then
        log "  No VPCs found in $region."
        continue
    fi

    echo "" >> "$OUTPUT_FILE"
    echo "## Region: $region" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    echo "$VPCS" | jq -c '.Vpcs[]' | while read -r vpc; do
        VPC_ID=$(echo "$vpc" | jq -r '.VpcId')
        VPC_NAME=$(echo "$vpc" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "unnamed"')
        VPC_CIDR=$(echo "$vpc" | jq -r '.CidrBlock')

        log "  Processing VPC: $VPC_NAME ($VPC_ID)"

        echo '```mermaid' >> "$OUTPUT_FILE"
        echo "graph TD" >> "$OUTPUT_FILE"
        echo "    %% VPC: $VPC_NAME ($VPC_CIDR)" >> "$OUTPUT_FILE"

        # --- Internet Gateway ---
        IGW=$(aws ec2 describe-internet-gateways --region "$region" \
            --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
            --query "InternetGateways[0].InternetGatewayId" --output text 2>/dev/null || echo "None")

        if [[ "$IGW" != "None" && -n "$IGW" ]]; then
            echo "    IGW_${IGW//[-.]/_}[\"🌐 Internet Gateway<br/>$IGW\"]" >> "$OUTPUT_FILE"
        fi

        # --- Subnets ---
        SUBNETS=$(aws ec2 describe-subnets --region "$region" \
            --filters "Name=vpc-id,Values=$VPC_ID" --output json --no-paginate 2>/dev/null || echo '{"Subnets":[]}')

        # Classify subnets as public/private based on route table
        ROUTE_TABLES=$(aws ec2 describe-route-tables --region "$region" \
            --filters "Name=vpc-id,Values=$VPC_ID" --output json --no-paginate 2>/dev/null || echo '{"RouteTables":[]}')

        # Find public subnet IDs (those with route to IGW)
        PUBLIC_SUBNET_IDS=$(echo "$ROUTE_TABLES" | jq -r '
            .RouteTables[] |
            select(.Routes[]? | .GatewayId? // "" | startswith("igw-")) |
            .Associations[].SubnetId // empty
        ' | sort -u)

        echo "" >> "$OUTPUT_FILE"
        echo "    subgraph VPC_${VPC_ID//[-.]/_}[\"VPC: $VPC_NAME<br/>$VPC_CIDR\"]" >> "$OUTPUT_FILE"

        # Group subnets
        PUBLIC_SUBS=()
        PRIVATE_SUBS=()
        echo "$SUBNETS" | jq -c '.Subnets[]' | while read -r subnet; do
            SUB_ID=$(echo "$subnet" | jq -r '.SubnetId')
            SUB_NAME=$(echo "$subnet" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "unnamed"')
            SUB_AZ=$(echo "$subnet" | jq -r '.AvailabilityZone')
            SUB_CIDR=$(echo "$subnet" | jq -r '.CidrBlock')

            if echo "$PUBLIC_SUBNET_IDS" | grep -q "$SUB_ID"; then
                echo "        subgraph PUB_${SUB_ID//[-.]/_}[\"🟢 Public: $SUB_NAME<br/>$SUB_AZ - $SUB_CIDR\"]" >> "$OUTPUT_FILE"
            else
                echo "        subgraph PRIV_${SUB_ID//[-.]/_}[\"🔒 Private: $SUB_NAME<br/>$SUB_AZ - $SUB_CIDR\"]" >> "$OUTPUT_FILE"
            fi

            # EC2 instances in this subnet
            INSTANCES=$(aws ec2 describe-instances --region "$region" \
                --filters "Name=subnet-id,Values=$SUB_ID" "Name=instance-state-name,Values=running,stopped" \
                --query "Reservations[].Instances[]" --output json 2>/dev/null || echo "[]")

            echo "$INSTANCES" | jq -c '.[]?' | while read -r inst; do
                INST_ID=$(echo "$inst" | jq -r '.InstanceId')
                INST_NAME=$(echo "$inst" | jq -r '([.Tags[]? | select(.Key=="Name").Value] | .[0]) // "unnamed"')
                INST_TYPE=$(echo "$inst" | jq -r '.InstanceType')
                INST_STATE=$(echo "$inst" | jq -r '.State.Name')
                if [[ "$INST_STATE" == "running" ]]; then
                    echo "            EC2_${INST_ID//[-.]/_}[\"💻 $INST_NAME<br/>$INST_TYPE\"]" >> "$OUTPUT_FILE"
                else
                    echo "            EC2_${INST_ID//[-.]/_}[\"⏸️ $INST_NAME<br/>$INST_TYPE (stopped)\"]" >> "$OUTPUT_FILE"
                fi
            done

            # RDS instances in this subnet (via subnet group)
            echo "        end" >> "$OUTPUT_FILE"
        done

        # --- NAT Gateways ---
        NATS=$(aws ec2 describe-nat-gateways --region "$region" \
            --filter "Name=vpc-id,Values=$VPC_ID" "Name=state,Values=available" \
            --query "NatGateways[]" --output json 2>/dev/null || echo "[]")

        echo "$NATS" | jq -c '.[]?' | while read -r nat; do
            NAT_ID=$(echo "$nat" | jq -r '.NatGatewayId')
            NAT_SUB=$(echo "$nat" | jq -r '.SubnetId')
            echo "        NAT_${NAT_ID//[-.]/_}[\"🔀 NAT Gateway<br/>$NAT_ID\"]" >> "$OUTPUT_FILE"
        done

        echo "    end" >> "$OUTPUT_FILE"

        # --- Load Balancers in this VPC ---
        ELBS=$(aws elbv2 describe-load-balancers --region "$region" --output json --no-paginate 2>/dev/null || echo '{"LoadBalancers":[]}')
        echo "$ELBS" | jq -c --arg vpc "$VPC_ID" '.LoadBalancers[] | select(.VpcId == $vpc)' | while read -r elb; do
            ELB_NAME=$(echo "$elb" | jq -r '.LoadBalancerName')
            ELB_TYPE=$(echo "$elb" | jq -r '.Type')
            ELB_ARN=$(echo "$elb" | jq -r '.LoadBalancerArn')
            ELB_DNS=$(echo "$elb" | jq -r '.DNSName')
            ELB_NODE="ELB_${ELB_NAME//[-.]/_}"

            echo "    ${ELB_NODE}[\"⚖️ $ELB_NAME<br/>$ELB_TYPE\"]" >> "$OUTPUT_FILE"

            # Connect IGW to ELB if internet-facing
            SCHEME=$(echo "$elb" | jq -r '.Scheme')
            if [[ "$SCHEME" == "internet-facing" && "$IGW" != "None" ]]; then
                echo "    IGW_${IGW//[-.]/_} --> ${ELB_NODE}" >> "$OUTPUT_FILE"
            fi

            # Get targets for this ELB
            TG_ARNS=$(aws elbv2 describe-target-groups --region "$region" \
                --load-balancer-arn "$ELB_ARN" \
                --query "TargetGroups[].TargetGroupArn" --output json 2>/dev/null || echo "[]")

            echo "$TG_ARNS" | jq -r '.[]?' | while read -r tg_arn; do
                TARGETS=$(aws elbv2 describe-target-health --region "$region" \
                    --target-group-arn "$tg_arn" \
                    --query "TargetHealthDescriptions[].Target.Id" --output json 2>/dev/null || echo "[]")

                echo "$TARGETS" | jq -r '.[]?' | while read -r target_id; do
                    if [[ "$target_id" == i-* ]]; then
                        echo "    ${ELB_NODE} --> EC2_${target_id//[-.]/_}" >> "$OUTPUT_FILE"
                    fi
                done
            done
        done

        # --- RDS in this VPC ---
        RDS_INSTANCES=$(aws rds describe-db-instances --region "$region" --output json 2>/dev/null || echo '{"DBInstances":[]}')
        echo "$RDS_INSTANCES" | jq -c --arg vpc "$VPC_ID" '.DBInstances[] | select(.DBSubnetGroup.VpcId == $vpc)' | while read -r rds; do
            RDS_ID=$(echo "$rds" | jq -r '.DBInstanceIdentifier')
            RDS_ENGINE=$(echo "$rds" | jq -r '.Engine')
            RDS_CLASS=$(echo "$rds" | jq -r '.DBInstanceClass')
            RDS_NODE="RDS_${RDS_ID//[-.]/_}"

            echo "    ${RDS_NODE}[(\"🗄️ $RDS_ID<br/>$RDS_ENGINE / $RDS_CLASS\")]" >> "$OUTPUT_FILE"

            # Connect EC2 to RDS via security groups
            RDS_SGS=$(echo "$rds" | jq -r '.VpcSecurityGroups[].VpcSecurityGroupId')
            # Find EC2 instances that share security groups with this RDS
            for sg in $RDS_SGS; do
                SG_INSTANCES=$(aws ec2 describe-instances --region "$region" \
                    --filters "Name=instance.group-id,Values=$sg" "Name=vpc-id,Values=$VPC_ID" \
                    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || echo "")
                for inst_id in $SG_INSTANCES; do
                    if [[ -n "$inst_id" ]]; then
                        echo "    EC2_${inst_id//[-.]/_} --> ${RDS_NODE}" >> "$OUTPUT_FILE"
                    fi
                done
            done
        done

        echo '```' >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
    done

    log "Region \033[1;33m$region\033[0m Complete."
done

log "✅ DONE. Architecture diagram saved to: $OUTPUT_FILE"

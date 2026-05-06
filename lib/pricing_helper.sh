#!/bin/bash
# lib/pricing_helper.sh
# Shared pricing data retrieval and caching library for optimization scripts.
# Source this file from optimization scripts: source ./lib/pricing_helper.sh
#
# Provides:
#   get_ec2_price()              - Get EC2 on-demand hourly price
#   get_rds_price()              - Get RDS on-demand hourly price
#   get_ebs_price()              - Get EBS pricing (per GB or per IOPS)
#   get_next_smaller_ec2_type()  - Get next smaller EC2 instance type in same family
#   get_next_smaller_rds_class() - Get next smaller RDS instance class in same family

# --- Pricing Cache Configuration ---
PRICING_CACHE_DIR="${PRICING_CACHE_DIR:-/tmp/aws_pricing_cache_$$}"
PRICING_FALLBACK_FILE="${PRICING_FALLBACK_FILE:-./lib/pricing_fallback.json}"

# Instance size hierarchy (smallest to largest)
INSTANCE_SIZE_HIERARCHY=(nano micro small medium large xlarge 2xlarge 4xlarge 8xlarge 12xlarge 16xlarge 24xlarge metal)

# Ensure cache directory exists
mkdir -p "$PRICING_CACHE_DIR" 2>/dev/null || true

# --- Internal Helper Functions ---

_pricing_log() {
    echo >&2 -e "[$(date +'%H:%M:%S')] [pricing] $*"
}

_get_cache_file() {
    local service="$1"
    local region="$2"
    local resource_key="$3"
    echo "${PRICING_CACHE_DIR}/${service}_${region}_${resource_key}.cache"
}

_read_cache() {
    local cache_file="$1"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
    fi
    return 1
}

_write_cache() {
    local cache_file="$1"
    local value="$2"
    echo "$value" > "$cache_file"
}

_get_size_index() {
    local size="$1"
    for i in "${!INSTANCE_SIZE_HIERARCHY[@]}"; do
        if [[ "${INSTANCE_SIZE_HIERARCHY[$i]}" == "$size" ]]; then
            echo "$i"
            return 0
        fi
    done
    echo "-1"
    return 1
}

_extract_instance_family() {
    # Extract family from instance type (e.g., "m5" from "m5.xlarge")
    local instance_type="$1"
    echo "$instance_type" | cut -d'.' -f1
}

_extract_instance_size() {
    # Extract size from instance type (e.g., "xlarge" from "m5.xlarge")
    local instance_type="$1"
    echo "$instance_type" | cut -d'.' -f2
}

_get_fallback_price() {
    local service="$1"
    local region="$2"
    local resource_key="$3"

    if [[ ! -f "$PRICING_FALLBACK_FILE" ]]; then
        echo ""
        return 1
    fi

    local price=""
    case "$service" in
        ec2)
            price=$(jq -r ".ec2.\"${region}\".\"${resource_key}\" // empty" "$PRICING_FALLBACK_FILE" 2>/dev/null)
            ;;
        rds)
            price=$(jq -r ".rds.\"${region}\".\"${resource_key}\" // empty" "$PRICING_FALLBACK_FILE" 2>/dev/null)
            ;;
        ebs)
            price=$(jq -r ".ebs.\"${region}\".\"${resource_key}\" // empty" "$PRICING_FALLBACK_FILE" 2>/dev/null)
            ;;
    esac

    echo "$price"
}

# --- Public API Functions ---

# get_ec2_price <instance_type> <region>
# Returns: hourly on-demand price in USD (e.g., "0.096")
# Falls back to pricing_fallback.json if API is unavailable
get_ec2_price() {
    local instance_type="$1"
    local region="$2"

    # Check cache first
    local cache_file
    cache_file=$(_get_cache_file "ec2" "$region" "$instance_type")
    local cached_value
    if cached_value=$(_read_cache "$cache_file"); then
        echo "$cached_value"
        return 0
    fi

    # Try AWS Pricing API
    local price=""
    if command -v aws >/dev/null 2>&1; then
        price=$(aws pricing get-products \
            --region us-east-1 \
            --service-code AmazonEC2 \
            --filters \
                "Type=TERM_MATCH,Field=instanceType,Value=${instance_type}" \
                "Type=TERM_MATCH,Field=location,Value=$(_region_to_location "$region")" \
                "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
                "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
                "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
                "Type=TERM_MATCH,Field=capacitystatus,Value=Used" \
            --query 'PriceList[0]' \
            --output text 2>/dev/null | \
            jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD' 2>/dev/null) || true
    fi

    # Fall back to local reference file if API failed
    if [[ -z "$price" || "$price" == "null" ]]; then
        price=$(_get_fallback_price "ec2" "$region" "$instance_type")
        if [[ -n "$price" ]]; then
            _pricing_log "⚠️ Using fallback pricing for EC2 ${instance_type} in ${region}"
        fi
    fi

    # Cache the result if we got a valid price
    if [[ -n "$price" && "$price" != "null" ]]; then
        _write_cache "$cache_file" "$price"
        echo "$price"
        return 0
    fi

    echo ""
    return 1
}

# get_rds_price <instance_class> <region>
# Returns: hourly on-demand price in USD (e.g., "0.240")
# Falls back to pricing_fallback.json if API is unavailable
get_rds_price() {
    local instance_class="$1"
    local region="$2"

    # Check cache first
    local cache_file
    cache_file=$(_get_cache_file "rds" "$region" "$instance_class")
    local cached_value
    if cached_value=$(_read_cache "$cache_file"); then
        echo "$cached_value"
        return 0
    fi

    # Try AWS Pricing API
    local price=""
    if command -v aws >/dev/null 2>&1; then
        price=$(aws pricing get-products \
            --region us-east-1 \
            --service-code AmazonRDS \
            --filters \
                "Type=TERM_MATCH,Field=instanceType,Value=${instance_class}" \
                "Type=TERM_MATCH,Field=location,Value=$(_region_to_location "$region")" \
                "Type=TERM_MATCH,Field=databaseEngine,Value=MySQL" \
            --query 'PriceList[0]' \
            --output text 2>/dev/null | \
            jq -r '.terms.OnDemand | to_entries[0].value.priceDimensions | to_entries[0].value.pricePerUnit.USD' 2>/dev/null) || true
    fi

    # Fall back to local reference file if API failed
    if [[ -z "$price" || "$price" == "null" ]]; then
        price=$(_get_fallback_price "rds" "$region" "$instance_class")
        if [[ -n "$price" ]]; then
            _pricing_log "⚠️ Using fallback pricing for RDS ${instance_class} in ${region}"
        fi
    fi

    # Cache the result if we got a valid price
    if [[ -n "$price" && "$price" != "null" ]]; then
        _write_cache "$cache_file" "$price"
        echo "$price"
        return 0
    fi

    echo ""
    return 1
}

# get_ebs_price <price_key> <region>
# price_key: gp2_per_gb, gp3_per_gb, io1_per_gb, io1_per_iops, io2_per_gb, io2_per_iops
# Returns: price per unit in USD (e.g., "0.10")
# Falls back to pricing_fallback.json if API is unavailable
get_ebs_price() {
    local price_key="$1"
    local region="$2"

    # Check cache first
    local cache_file
    cache_file=$(_get_cache_file "ebs" "$region" "$price_key")
    local cached_value
    if cached_value=$(_read_cache "$cache_file"); then
        echo "$cached_value"
        return 0
    fi

    # For EBS, we primarily use the fallback file since the Pricing API
    # query for EBS is complex and region-specific pricing is relatively stable
    local price=""
    price=$(_get_fallback_price "ebs" "$region" "$price_key")

    if [[ -n "$price" && "$price" != "null" ]]; then
        _write_cache "$cache_file" "$price"
        echo "$price"
        return 0
    fi

    echo ""
    return 1
}

# get_next_smaller_ec2_type <current_type>
# Returns: next smaller instance type in the same family
# Example: m5.xlarge -> m5.large, t3.medium -> t3.small
# Returns empty string if already at smallest size (nano)
get_next_smaller_ec2_type() {
    local current_type="$1"
    local family
    local size

    family=$(_extract_instance_family "$current_type")
    size=$(_extract_instance_size "$current_type")

    local current_index
    current_index=$(_get_size_index "$size")

    if [[ "$current_index" -le 0 ]]; then
        # Already at smallest size or size not found
        echo ""
        return 1
    fi

    local smaller_index=$((current_index - 1))
    local smaller_size="${INSTANCE_SIZE_HIERARCHY[$smaller_index]}"

    echo "${family}.${smaller_size}"
    return 0
}

# get_next_smaller_rds_class <current_class>
# Returns: next smaller RDS instance class in the same family
# Example: db.r5.xlarge -> db.r5.large, db.t3.medium -> db.t3.small
# Returns empty string if already at smallest size
get_next_smaller_rds_class() {
    local current_class="$1"

    # RDS classes have format: db.<family>.<size>
    local prefix="db."
    local without_prefix="${current_class#db.}"
    local family
    local size

    family=$(echo "$without_prefix" | cut -d'.' -f1)
    size=$(echo "$without_prefix" | cut -d'.' -f2)

    local current_index
    current_index=$(_get_size_index "$size")

    if [[ "$current_index" -le 0 ]]; then
        # Already at smallest size or size not found
        echo ""
        return 1
    fi

    local smaller_index=$((current_index - 1))
    local smaller_size="${INSTANCE_SIZE_HIERARCHY[$smaller_index]}"

    echo "db.${family}.${smaller_size}"
    return 0
}

# --- Region to Location Mapping (for Pricing API) ---
_region_to_location() {
    local region="$1"
    case "$region" in
        us-east-1)      echo "US East (N. Virginia)" ;;
        us-east-2)      echo "US East (Ohio)" ;;
        us-west-1)      echo "US West (N. California)" ;;
        us-west-2)      echo "US West (Oregon)" ;;
        ap-southeast-1) echo "Asia Pacific (Singapore)" ;;
        ap-southeast-2) echo "Asia Pacific (Sydney)" ;;
        ap-southeast-3) echo "Asia Pacific (Jakarta)" ;;
        ap-northeast-1) echo "Asia Pacific (Tokyo)" ;;
        ap-northeast-2) echo "Asia Pacific (Seoul)" ;;
        ap-south-1)     echo "Asia Pacific (Mumbai)" ;;
        eu-west-1)      echo "EU (Ireland)" ;;
        eu-west-2)      echo "EU (London)" ;;
        eu-central-1)   echo "EU (Frankfurt)" ;;
        *)              echo "$region" ;;
    esac
}

# Configuration Guide

## config.ini

The main configuration file controls which reports are enabled. Set a value to `1` to enable, `0` to disable.

### Sections

```ini
; =============================================================================
; Inventory Reports (no prefix)
; =============================================================================
ec2=1           # Amazon EC2 instances
rds=1           # Amazon RDS databases
s3=1            # Amazon S3 buckets
lambda=0        # AWS Lambda functions
# ... (50+ services available)

; =============================================================================
; Price Optimization Reports (opt_ prefix)
; =============================================================================
opt_ec2_rightsizing=0    # EC2 right-sizing recommendations
opt_rds_rightsizing=0    # RDS right-sizing recommendations
opt_idle_resources=0     # Idle resource detection
opt_ebs_optimization=0   # EBS volume optimization
opt_ri_sp_advisor=0      # RI/Savings Plans advisor
opt_data_transfer=0      # Data transfer cost optimization
opt_s3_storage=0         # S3 storage class optimization
opt_efs_storage=0        # EFS storage optimization
opt_trusted_advisor=0    # Trusted Advisor recommendations
opt_summary=0            # Aggregated summary

; =============================================================================
; Security Reports (sec_ prefix) — coming soon
; =============================================================================
# sec_iam_audit=0
# sec_sg_check=0

; =============================================================================
; Parallel Configuration
; =============================================================================
parallel=1       # Enable parallel execution (0=sequential)
max_parallel=2   # Max concurrent scripts (2-4 recommended)
```

## Run Modes (`--mode` / `-m`)

Modes filter which scripts run based on their config key prefix:

| Mode | Includes | Config Key Pattern |
|------|----------|-------------------|
| `all` | Everything enabled | All keys |
| `inventory` | Only inventory reports | Keys without `opt_` or `sec_` prefix |
| `optimize` | Only optimization reports | Keys starting with `opt_` |
| `security` | Only security reports | Keys starting with `sec_` |

### Combining Modes

Use comma-separated values to combine:

```bash
# Optimization + Security only (skip inventory)
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m optimize,security

# Inventory + Optimization (skip security)
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m inventory,optimize
```

### Mode Behavior

| Mode includes... | Inventory Excel | Optimization Excel | Security Excel |
|-----------------|-----------------|-------------------|----------------|
| `inventory` | ✅ Generated | ❌ Skipped | ❌ Skipped |
| `optimize` | ❌ Skipped | ✅ Generated | ❌ Skipped |
| `security` | ❌ Skipped | ❌ Skipped | ✅ Generated |
| `all` (default) | ✅ Generated | ✅ Generated | ✅ Generated |

## Environment Variables

### Optimization Thresholds

| Variable | Default | Used By |
|----------|---------|---------|
| `UTIL_THRESHOLD` | 30 | EC2/RDS right-sizing, EFS optimization |
| `IDLE_THRESHOLD` | 5 | Idle resource detection |
| `DATA_TRANSFER_ALERT_THRESHOLD` | 100 | Data transfer optimization |

### System Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OUTPUT_DIR` | `export/aws-cloud-report-YYYY-MM-DD` | Output directory path |
| `START_DATE` | (from `-b` flag) | Analysis period start |
| `END_DATE` | (from `-e` flag) | Analysis period end |

## Regions

Default regions: `ap-southeast-1`, `ap-southeast-3`

Override with `-r` flag:

```bash
# Single region
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -r us-east-1

# Multiple regions
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -r us-east-1,eu-west-1,ap-southeast-1
```

## Parallel Execution

```ini
parallel=1       # 0=sequential, 1=parallel
max_parallel=2   # Concurrent script limit
```

**Recommendations:**
- CloudShell: `max_parallel=2` (limited resources)
- EC2/local with good network: `max_parallel=4`
- Large accounts (1000+ resources): `max_parallel=2` to avoid API throttling

## AWS Permissions Required

The scripts need read-only access to AWS services. Recommended IAM policy:
- `ReadOnlyAccess` managed policy covers most scripts
- `ce:GetCostAndUsage` for billing and data transfer reports
- `pricing:GetProducts` for optimization pricing lookups
- `support:DescribeTrustedAdvisor*` for Trusted Advisor (requires Business/Enterprise support)

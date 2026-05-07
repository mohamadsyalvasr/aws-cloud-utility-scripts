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
# ... (60+ services available)

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
opt_cost_trend=0         # Cost trend analysis (period comparison)
opt_summary=0            # Aggregated summary

; =============================================================================
; Security Audit Reports (sec_ prefix)
; =============================================================================
sec_trusted_advisor=0    # Trusted Advisor security (primary source)
sec_iam_audit=0          # IAM security audit (MFA, keys, policies)
sec_sg_audit=0           # Security Group audit (open ports)
sec_s3_audit=0           # S3 bucket security (public access, encryption)
sec_encryption_audit=0   # Encryption audit (EBS/RDS/KMS)
sec_network_audit=0      # Network security (VPC flow logs, subnets)
sec_logging_audit=0      # Logging & monitoring (CloudTrail, GuardDuty)
sec_securityhub=0        # Security Hub findings
sec_summary=0            # Security summary report

; =============================================================================
; Additional Inventory Reports
; =============================================================================
tagging_compliance=0     # Tagging compliance check (MANDATORY_TAGS env var)
resource_lifecycle=0     # Resource age/lifecycle check (RESOURCE_AGE_THRESHOLD env var)
delta_report=0           # Historical comparison vs baseline (export/baseline/)
scorecard=0              # Executive summary scorecard (runs LAST, reads other CSVs)

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

### Excel Output Modes (`--excel-mode`)

Controls how inventory reports are structured in the Excel file:

| Flag | Behavior |
|------|----------|
| `--excel-mode single` | All inventory reports in 1 sheet (default, scrollable) |
| `--excel-mode multi` | Each AWS service gets its own sheet (easier navigation) |
| *(mode=all)* | Automatic: 3 sheets grouped by type (Inventory/Optimization/Security) |

**Note:** `--excel-mode` only affects inventory reports. Optimization and security always use multi-sheet (1 sheet per category).

```bash
# Inventory: 1 sheet per AWS service
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m inventory --excel-mode multi

# Mode all: automatic 3 sheets (Inventory, Optimization, Security)
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31
```

## Environment Variables

### Optimization Thresholds

| Variable | Default | Used By |
|----------|---------|---------|
| `UTIL_THRESHOLD` | 30 | EC2/RDS right-sizing, EFS optimization |
| `IDLE_THRESHOLD` | 5 | Idle resource detection |
| `DATA_TRANSFER_ALERT_THRESHOLD` | 100 | Data transfer optimization |
| `COST_CHANGE_THRESHOLD` | 20 | Cost trend analysis (% increase for "High" alert) |

### Feature Configuration

| Variable | Default | Used By |
|----------|---------|---------|
| `MANDATORY_TAGS` | `Environment,Owner,CostCenter,Project` | Tagging compliance report |
| `RESOURCE_AGE_THRESHOLD` | 365 | Resource lifecycle report (days) |

### Notification Configuration

| Variable | Required | Description |
|----------|----------|-------------|
| `NOTIFY_SLACK` | No | Set to `1` to enable Slack notifications |
| `SLACK_WEBHOOK_URL` | When NOTIFY_SLACK=1 | Slack incoming webhook URL |
| `NOTIFY_TEAMS` | No | Set to `1` to enable Teams notifications |
| `TEAMS_WEBHOOK_URL` | When NOTIFY_TEAMS=1 | Teams incoming webhook URL |
| `NOTIFY_SNS` | No | Set to `1` to enable email via SNS |
| `SNS_TOPIC_ARN` | When NOTIFY_SNS=1 | SNS topic ARN for email delivery |

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

## Auto-Discovery Mode

Instead of manually enabling reports in config.ini, you can let the tool
auto-detect which services are active based on your AWS billing data:

```bash
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 --auto-discover
```

**How it works:**
1. Queries Cost Explorer for services with non-zero cost → enables matching reports
2. Queries Cost Explorer for regions with non-zero cost → sets active regions
3. Maps billing service names to report config keys using pattern matching
4. Reports unmapped services (in billing but no script available)
5. Falls back to config.ini / default regions if Cost Explorer is unavailable

**Region auto-discovery:**
- If `-r` is NOT explicitly passed, regions are auto-detected from billing
- If `-r` IS passed, region auto-discovery is skipped (your explicit regions are used)
- Global services (IAM, S3, CloudFront, Route 53) don't need region detection

**Requirements:**
- Cost Explorer access (`ce:GetCostAndUsage` permission)
- The `-b` and `-e` date flags (used as the billing lookup period)

**Always enabled regardless of billing:**
- `iam` — IAM is global and always relevant
- `billing` — proves Cost Explorer works

**Pattern matching handles variations:**
- "Amazon Elastic Compute Cloud - Compute" → enables `ec2`, `ebs_detailed`
- "EC2 - Other" → enables `ec2`, `ebs_detailed`, `ebs_utilization`, `natgateway`
- "Amazon Virtual Private Cloud" → enables `vpc`, `vpn`

**Combining with modes:**
```bash
# Auto-discover inventory + run all optimization
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -a -m all

# Auto-discover inventory only
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -a -m inventory
```

**Important:** Auto-discovery applies to **inventory** and **optimization** reports. Security reports (`sec_*`) are not discoverable from billing and must be selected manually.

| Mode | Auto-discover behavior |
|------|----------------------|
| `inventory` or `all` | ✅ Discovers inventory services + optimization reports from billing |
| `optimize` | ✅ Discovers which optimization reports to run based on billing services |
| `security` | ❌ Skipped: use config.ini or launcher checklist for sec_* keys |
| `optimize,security` | ✅ Optimization auto-discovered, security via checklist |

**Optimization auto-mapping from billing:**
- EC2 in billing → enables `opt_ec2_rightsizing`, `opt_ri_sp_advisor`, `opt_idle_resources`
- RDS in billing → enables `opt_rds_rightsizing`, `opt_idle_resources`
- EBS in billing → enables `opt_ebs_optimization`
- S3 in billing → enables `opt_s3_storage`
- EFS in billing → enables `opt_efs_storage`
- Data Transfer/NAT Gateway in billing → enables `opt_data_transfer`
- `opt_summary` and `opt_cost_trend` are always enabled when optimize mode is active

**Skipped services (known billing items without report scripts):**
- Tax, AWS CloudShell, AWS Amplify, AWS DataSync, Amazon QuickSight, Amazon FSx
- These are recognized in billing but intentionally don't generate inventory reports

**Unmapped services warning:**

When a service appears in billing but has no matching report script, the tool displays a warning listing those services. This helps you identify visibility gaps — services you're paying for but don't have inventory reports for.

Common unmapped services (expected, no action needed):
- `Tax` — not a service, just tax charges
- `AWS Support (Business)` — support plan fee
- `AWS Marketplace` — third-party software

If you see a real AWS service listed as unmapped, consider creating a report script for it (see [Adding New Reports](adding-reports.md)).

## AWS Permissions Required

The scripts need read-only access to AWS services. Recommended IAM policy:
- `ReadOnlyAccess` managed policy covers most scripts
- `ce:GetCostAndUsage` for billing and data transfer reports
- `pricing:GetProducts` for optimization pricing lookups
- `support:DescribeTrustedAdvisor*` for Trusted Advisor (requires Business/Enterprise support)

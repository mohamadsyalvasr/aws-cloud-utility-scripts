# Price Optimization

The optimization module analyzes AWS resource utilization and generates actionable cost-saving recommendations. Results are combined into a single multi-sheet Excel file.

## How It Works

1. Scripts collect CloudWatch metrics for each resource (CPU, memory, IOPS, etc.)
2. Metrics are compared against configurable thresholds
3. Resources below thresholds are flagged with specific recommendations
4. Estimated monthly savings are calculated using AWS Pricing API (with local fallback)
5. All results are aggregated into a summary with priority classification

## Optimization Scripts

| Script | What It Does |
|--------|-------------|
| `ec2_rightsizing_report.sh` | Flags EC2 instances where both CPU and memory are below threshold. Recommends next smaller instance type in same family. |
| `rds_rightsizing_report.sh` | Flags RDS instances with low CPU and high freeable memory. Doubles savings for Multi-AZ. |
| `idle_resources_report.sh` | Detects: unattached EBS, unassociated EIPs, zero-invocation Lambdas, zero-connection RDS, zero-request ELBs. |
| `ebs_optimization_report.sh` | Recommends gp2→gp3 migration for all gp2 volumes. Flags io1/io2 with IOPS utilization below 30%. |
| `ri_sp_advisor_report.sh` | Identifies continuously running instances not covered by RI/SP. Calculates 1yr/3yr savings. |
| `data_transfer_optimization_report.sh` | Analyzes NAT Gateway costs and cross-region transfers via Cost Explorer. |
| `s3_storage_optimization_report.sh` | Recommends lifecycle policies, Intelligent-Tiering, Glacier transitions. Checks versioning overhead. |
| `efs_storage_optimization_report.sh` | Recommends Lifecycle Management for Standard→IA transitions. Flags unused file systems. |
| `trusted_advisor_report.sh` | Pulls cost optimization recommendations from AWS Trusted Advisor (requires Business/Enterprise support). |
| `optimization_summary_report.sh` | Aggregates all findings with total savings and priority (High/Medium/Low). |

## Configurable Thresholds

Set via environment variables before running:

| Variable | Default | Description |
|----------|---------|-------------|
| `UTIL_THRESHOLD` | 30 | CPU/Memory % below which a resource is underutilized |
| `IDLE_THRESHOLD` | 5 | % below which a resource is considered idle |
| `DATA_TRANSFER_ALERT_THRESHOLD` | 100 | USD/month above which data transfer triggers recommendation |

```bash
# Example: more aggressive thresholds
UTIL_THRESHOLD=20 DATA_TRANSFER_ALERT_THRESHOLD=50 \
  ./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m optimize
```

## Excel Output

When optimization reports run, a multi-sheet Excel file is generated:

| Sheet | Content |
|-------|---------|
| Summary | Aggregated findings, total savings, priority per category |
| EC2 Right-Sizing | Instance ID, current/recommended type, savings |
| RDS Right-Sizing | DB ID, engine, current/recommended class, savings |
| Idle Resources | Resource type, ID, reason, monthly cost, action |
| EBS Optimization | Volume ID, type, IOPS usage, recommendation, savings |
| RI-SP Advisor | Instance ID, type, on-demand cost, 1yr/3yr savings |
| Data Transfer | Resource, transfer type, volume, cost, recommendation |
| S3 Storage | Bucket, size, storage distribution, versioning, recommendation |
| EFS Storage | File system, size breakdown, throughput, recommendation |

**Highlighting:**
- Rows with savings > $100/month → light green
- Rows with savings > $500/month → darker green
- Summary TOTAL row → blue

## Pricing Data

Scripts use the **AWS Pricing API** (`us-east-1`) for accurate calculations. If unavailable:
- Falls back to `lib/pricing_fallback.json`
- Logs a warning
- Continues with fallback prices

Pricing is cached per execution run (temp directory) to minimize API calls.

**Covered in fallback:**
- EC2: t3, m5, c5, r5 families (ap-southeast-1, ap-southeast-3)
- RDS: db.t3, db.m5, db.r5, db.c5 families
- EBS: gp2, gp3, io1, io2, st1, sc1
- S3: Standard, IA, Intelligent-Tiering, Glacier, Deep Archive
- EFS: Standard, Infrequent Access

## KeepAlive Tag

Resources tagged with `KeepAlive=true` are excluded from idle resource recommendations. Use this to protect intentionally idle resources (DR standby, scheduled jobs, etc.).

## Trusted Advisor Integration

The `trusted_advisor_report.sh` script pulls pre-computed cost optimization recommendations directly from AWS Trusted Advisor. This is the fastest way to get recommendations since AWS has already analyzed your account.

**Requirements:** Business or Enterprise Support plan. If unavailable, the script logs a warning and exits gracefully.

## Performance Tips

Optimization scripts make many CloudWatch API calls per resource. To speed things up:

1. **Enable parallel mode:** `parallel=1` and `max_parallel=3` in config.ini
2. **Run from CloudShell:** Lower latency to AWS APIs
3. **Enable only what you need:** Don't enable all opt_* scripts if you only care about EC2
4. **Use shorter analysis periods:** 7-14 days instead of 30 days (fewer datapoints)

## Priority Classification

The summary report classifies recommendations:

| Priority | Criteria |
|----------|----------|
| **High** | Total category savings > $100/month |
| **Medium** | Total category savings $20–$100/month |
| **Low** | Total category savings < $20/month |

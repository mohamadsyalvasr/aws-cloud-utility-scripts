# AWS Cloud Utility Scripts

A toolkit for AWS infrastructure **inventory reporting**, **cost optimization**, and **security auditing**. Runs on AWS CloudShell or any environment with AWS CLI configured.

---

## Quick Start

```bash
git clone https://github.com/mohamadsyalvasr/aws-cloud-utility-scripts
cd aws-cloud-utility-scripts
chmod +x main_report_runner.sh launcher.sh
```

**Easiest way** — use the interactive launcher:

```bash
./launcher.sh
```

Or run directly via CLI:

```bash
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31
```

---

## What It Does

| Mode | Purpose | Usage |
|------|---------|-------|
| **Inventory** | Collect detailed data from 60+ AWS services into CSV/Excel | `./main_report_runner.sh -b ... -e ...` |
| **Optimize** | Analyze utilization and recommend cost savings | `-m optimize` |
| **Security** | Audit security configurations and compliance | `-m security` |
| **All** | Run all modes at once | `-m all` |

Modes can be combined: `-m optimize,security`

---

## Prerequisites

| Tool | Notes |
|------|-------|
| AWS CLI v2 | Pre-installed on CloudShell |
| jq | JSON processor |
| bc | Calculator |
| python3 + pandas + xlsxwriter | For Excel generation |
| zip | For archiving output |

Install Python dependencies (if not already available):

```bash
pip3 install pandas xlsxwriter
```

**Optional:**
- **Bedrock Model Invocation Logging** — enable in Bedrock Console for per-user token usage data
- **QuickSight subscription** — required for user inventory report

---

## Command-Line Options

| Option | Description |
|--------|-------------|
| `-b <YYYY-MM-DD>` | **Required.** Start date |
| `-e <YYYY-MM-DD>` | **Required.** End date |
| `-r <regions>` | Comma-separated regions to scan. Default: `ap-southeast-1,ap-southeast-3` |
| `-m <mode>` | Run mode: `inventory`, `optimize`, `security`, `all` |
| `-a` / `--auto-discover` | Auto-detect active services from billing data |
| `--excel-mode <mode>` | `single` (1 sheet) or `multi` (1 sheet per service) |
| `-s` | Sum all attached EBS volumes in EC2 report |
| `-h` | Show help |

---

## Auto-Discovery

With `--auto-discover`, the tool automatically:
1. Queries Cost Explorer to find which services have non-zero cost → enables only those reports
2. Detects which regions are active → scans only those regions

```bash
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 --auto-discover
```

No need to manually toggle services in config.ini — the tool figures out what you're using.

---

## Output

After completion, output is located at:

```
export/aws-cloud-report-YYYY-MM-DD/
├── *.csv                                    # Individual CSV per service
├── Combined_AWS_Reports_<Account>.xlsx      # Inventory Excel
├── AWS_Optimization_Report_<Account>.xlsx   # Optimization Excel (multi-sheet)
└── AWS_Security_Report_<Account>.xlsx       # Security Excel (multi-sheet)

aws_reports_YYYY-MM-DD.zip                   # Everything zipped for download
```

Excel filenames automatically include Account Name/ID for easy identification across multiple accounts.

---

## Configuration

Edit `config.ini` to enable/disable individual reports:

```ini
; Inventory (no prefix)
ec2=1
rds=1
s3=1
lambda=0

; Optimization (opt_ prefix)
opt_ec2_rightsizing=1
opt_idle_resources=1

; Security (sec_ prefix)
sec_iam_audit=1
sec_sg_audit=1

; Parallel execution
parallel=1
max_parallel=2
```

Set `=1` to enable, `=0` to disable.

---

## Inventory Reports (60+ Services)

<details>
<summary>Click to expand full list</summary>

| Service | Script | Data Collected |
|---------|--------|----------------|
| ACM | `acm_report.sh` | Certificates (domain, status, expiry) |
| API Gateway | `apigateway_report.sh` | REST/HTTP/WebSocket APIs |
| App Runner | `apprunner_report.sh` | Services |
| ASG | `asg_report.sh` | Auto Scaling Groups |
| Backup | `backup_report.sh` | Vaults + Plans |
| Bedrock | `bedrock_report.sh` | Models & endpoints |
| Bedrock Usage | `bedrock_usage_report.sh` | Token usage per user + cost |
| Billing | `aws_billing_report.sh` | Cost per service |
| CloudFront | `cloudfront_report.sh` | Distributions |
| CloudWatch | `cloudwatch_report.sh` | Alarms + Log Groups |
| CodePipeline | `codepipeline_report.sh` | CI/CD Pipelines |
| Cognito | `cognito_report.sh` | User Pools |
| Config | `config_report.sh` | Compliance rules |
| Data Transfer | `data_transfer_report.sh` | Network cost + bytes per instance |
| Direct Connect | `directconnect_report.sh` | Connections |
| DocumentDB | `documentdb_report.sh` | Clusters |
| DynamoDB | `dynamodb_report.sh` | Tables |
| EBS | `ebs_report.sh` | Volumes (type, size, IOPS) |
| EBS Utilization | `ebs_utilization_report.sh` | Read/write bytes, disk used % |
| EC2 | `aws_ec2_report.sh` | Instances + CPU/Memory metrics |
| ECR | `ecr_report.sh` | Container repositories |
| ECS | `ecs_report.sh` | Clusters + tasks |
| EFS | `efs_report.sh` | File systems (size in GiB) |
| EKS | `eks_report.sh` | Kubernetes clusters |
| ElastiCache | `elasticache_report.sh` | Cache clusters |
| ELB | `elb_report.sh` | Load Balancers (ALB/NLB/GWLB) |
| EventBridge | `eventbridge_report.sh` | Rules + targets |
| Glue | `glue_report.sh` | Jobs + Crawlers + Databases |
| Grafana | `grafana_report.sh` | Managed Grafana workspaces |
| IAM | `iam_report.sh` | Users |
| Kinesis | `kinesis_report.sh` | Data streams |
| KMS | `kms_report.sh` | Encryption keys |
| Lambda | `lambda_report.sh` | Functions |
| Lightsail | `lightsail_report.sh` | Instances |
| MQ | `mq_report.sh` | Message brokers |
| MSK | `msk_report.sh` | Kafka clusters |
| NAT Gateway | `natgateway_report.sh` | NAT Gateways |
| Neptune | `neptune_report.sh` | Graph DB clusters |
| OpenSearch | `opensearch_report.sh` | Search domains |
| QuickSight | `quicksight_usage_report.sh` | Users + cost |
| RDS | `aws_rds_report.sh` | DB instances + metrics |
| Redshift | `redshift_report.sh` | Data warehouse clusters |
| Reserved Instances | `aws_ri_report.sh` | RI inventory |
| Route 53 | `route53_report.sh` | Hosted zones |
| S3 | `s3_report.sh` | Buckets (size, objects) |
| SageMaker | `sagemaker_report.sh` | ML endpoints |
| Savings Plans | `aws_sp_report.sh` | SP inventory |
| Secrets Manager | `secrets_manager_report.sh` | Secrets |
| SES | `ses_report.sh` | Email identities |
| SNS | `sns_report.sh` | Topics + subscriptions |
| SQS | `sqs_report.sh` | Queues |
| SSM Parameters | `ssm_params_report.sh` | Parameter Store |
| Step Functions | `stepfunctions_report.sh` | State machines |
| Transfer Family | `transfer_family_report.sh` | SFTP/FTP servers |
| Transit Gateway | `transitgateway_report.sh` | TGW + attachments |
| VPC | `vpc_report.sh` | VPCs, subnets, IGW, NAT, SG, EIP |
| VPN | `vpn_report.sh` | Site-to-Site VPN |
| WAF | `waf_report.sh` | Web ACLs + request counts |
| WorkSpaces | `aws_workspaces_report.sh` | Virtual desktops |

</details>

---

## Additional Features

| Feature | Description |
|---------|-------------|
| **Tagging Compliance** | Check resources for mandatory tags |
| **Resource Lifecycle** | Identify stale AMIs, deprecated runtimes, outdated EKS versions |
| **Cost Trend** | Compare costs between periods, highlight >20% increases |
| **Delta Report** | Compare current run vs previous — detect new/removed/changed resources |
| **Scorecard** | Executive summary with Health Score (0-100) |
| **Multi-Account** | Run reports across multiple AWS accounts via cross-account roles |
| **Notifications** | Send summary to Slack, Teams, or Email (SNS) |

---

## Multi-Account

To run reports across multiple accounts:

```bash
# Edit account list
vim accounts.conf

# Run
./multi_account_runner.sh -b 2025-08-01 -e 2025-08-31
```

Details: [docs/multi-account-setup.md](docs/multi-account-setup.md)

---

## Adding a New Report

Two steps:

1. Create a script in `script/inventory/` (follow existing pattern)
2. Add one line to `lib/report_registry.sh`:
   ```bash
   "config_key|./script/inventory/my_report.sh|-r"
   ```

Details: [docs/adding-reports.md](docs/adding-reports.md)

---

## Project Structure

```
.
├── main_report_runner.sh          # Main orchestrator (CLI)
├── launcher.sh                    # Interactive launcher (TUI)
├── multi_account_runner.sh        # Multi-account wrapper
├── accounts.conf                  # Target account list
├── config.ini                     # Report toggles
├── lib/
│   ├── logger.sh                 # Logging
│   ├── task_runner.sh            # Execution engine
│   ├── report_registry.sh       # Report definitions registry
│   ├── auto_discover.sh         # Auto-discovery from billing
│   ├── pricing_helper.sh        # AWS Pricing API
│   ├── notifier.sh              # Slack/Teams/SNS notifications
│   └── python/                   # Excel generators
├── script/
│   ├── inventory/                # 60+ inventory scripts
│   ├── optimization/             # Cost optimization scripts
│   ├── security/                 # Security audit scripts
│   └── compliance/               # Compliance & governance
├── docs/                          # Full documentation
└── web/                           # Web UI (optional)
```

---

## Documentation

| Document | Contents |
|----------|----------|
| [Inventory Reports](docs/inventory-reports.md) | All 60+ report scripts with column details |
| [Price Optimization](docs/price-optimization.md) | How optimization works, thresholds, recommendations |
| [Security Audit](docs/security-audit.md) | Security auditing, severity levels |
| [Multi-Account Setup](docs/multi-account-setup.md) | Cross-account role setup |
| [Configuration Guide](docs/configuration.md) | All config.ini options and environment variables |
| [Adding New Reports](docs/adding-reports.md) | How to add your own report scripts |

---

## License

Copyright 2026

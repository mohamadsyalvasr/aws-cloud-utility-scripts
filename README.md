# AWS Inventory Report Generator

This repository contains a set of Bash scripts designed to automate the generation of various AWS resource inventory reports. The main script, `main_report_runner.sh`, provides a single entry point to run all reports (sequentially or in parallel), making it easy to generate comprehensive reports with a single command.

Reports are designed to run on **AWS CloudShell** or any environment with AWS CLI configured.

## Included Scripts

| Script | AWS Service | Description |
|--------|-------------|-------------|
| `acm_report.sh` | AWS ACM (Certificate Manager) | Certificates inventory (domain, status, type, key algo, expiry, in-use). |
| `apigateway_report.sh` | Amazon API Gateway | REST/HTTP/WebSocket APIs inventory (name, type, endpoint, protocol). |
| `asg_report.sh` | Auto Scaling Group | Reports on Auto Scaling Groups (min/max/desired capacity, instance count). |
| `aws_billing_report.sh` | AWS Billing & Cost Management | Gathers all consumed services and their costs from Cost Explorer API. |
| `aws_ec2_report.sh` | Amazon EC2 (Elastic Compute Cloud) | Detailed report on EC2 instances with specs and average CPU/Memory utilization. |
| `aws_rds_report.sh` | Amazon RDS (Relational Database Service) | Detailed report on RDS instances with specs, CPU, memory, disk, and latency metrics. |
| `aws_ri_report.sh` | EC2 Reserved Instances | Reports on purchased Reserved Instances (type, term, payment, state). |
| `aws_sp_report.sh` | AWS Savings Plans | Reports on Savings Plans (type, commitment, payment option). Global API. |
| `aws_workspaces_report.sh` | Amazon WorkSpaces | Reports on WorkSpaces (compute, volumes, running mode, last active time). |
| `backup_report.sh` | AWS Backup | Backup Vaults (recovery points, encryption) + Backup Plans (name, last execution). |
| `cloudfront_report.sh` | Amazon CloudFront (CDN) | Reports on CloudFront Distributions. Global API. |
| `cloudwatch_report.sh` | Amazon CloudWatch | Alarms inventory (state, threshold) + Log Groups (size, retention). |
| `codepipeline_report.sh` | AWS CodePipeline | Pipelines inventory (name, ARN, stage count, created/updated dates). |
| `config_report.sh` | AWS Config | Config rules inventory (compliance status, source type, noncompliant count). |
| `data_transfer_report.sh` | AWS Data Transfer | Cost breakdown from Cost Explorer + Network In/Out per EC2 instance (GB). |
| `directconnect_report.sh` | AWS Direct Connect | Connections inventory (state, bandwidth, location, VLAN, partner, LAG). |
| `dynamodb_report.sh` | Amazon DynamoDB (NoSQL Database) | Reports on DynamoDB tables (status, item count, size). |
| `ebs_report.sh` | Amazon EBS (Elastic Block Store) | Detailed inventory of EBS volumes (type, size, IOPS, throughput, state). |
| `ebs_utilization_report.sh` | Amazon EBS (Elastic Block Store) | EBS volumes with utilization metrics (read/write bytes, disk used %). |
| `ecr_report.sh` | Amazon ECR (Elastic Container Registry) | Inventory of ECR repositories (image count, tag mutability, scan config, encryption). |
| `ecs_report.sh` | Amazon ECS (Elastic Container Service) | Reports on ECS Clusters (running/pending tasks, active services). |
| `efs_report.sh` | Amazon EFS (Elastic File System) | Reports on EFS file systems (size in GiB by storage class, state). |
| `eks_report.sh` | Amazon EKS (Elastic Kubernetes Service) | Reports on EKS clusters (version, status, creation date). |
| `elasticache_report.sh` | Amazon ElastiCache | Reports on ElastiCache clusters (node type, engine). |
| `elb_report.sh` | Elastic Load Balancing (ALB/NLB/GWLB) | Reports on all ELBv2 load balancers (type, scheme, state, DNS). |
| `eventbridge_report.sh` | Amazon EventBridge | Rules inventory across all event buses (state, schedule, target count). |
| `glue_report.sh` | AWS Glue (ETL) | Jobs (worker type, version, last run) + Crawlers (state, schedule) + Databases. |
| `iam_report.sh` | AWS IAM (Identity and Access Management) | Reports on IAM Users (create date, password last used). Global API. |
| `kinesis_report.sh` | Amazon Kinesis Data Streams | Streams inventory (status, mode, shard count, retention, encryption). |
| `kms_report.sh` | AWS KMS (Key Management Service) | Inventory of KMS keys (alias, state, usage, spec, rotation status). |
| `lambda_report.sh` | AWS Lambda (Serverless Compute) | Reports on Lambda functions (runtime, handler, code size). |
| `natgateway_report.sh` | NAT Gateway | NAT Gateways inventory (state, VPC, subnet, connectivity type, IPs). |
| `opensearch_report.sh` | Amazon OpenSearch Service | Domains inventory (engine version, instance type, storage, VPC, endpoint). |
| `redshift_report.sh` | Amazon Redshift | Clusters inventory (node type, nodes, status, endpoint, encryption). |
| `route53_report.sh` | Amazon Route 53 (DNS) | Hosted zones inventory (name, type, record count). Global API. |
| `s3_report.sh` | Amazon S3 (Simple Storage Service) | Reports on S3 buckets (object count, total size via CloudWatch). |
| `secrets_manager_report.sh` | AWS Secrets Manager | Secrets inventory (rotation status, last rotated/accessed, created date). |
| `ses_report.sh` | Amazon SES (Simple Email Service) | Email/domain identities inventory (verification status). |
| `sns_report.sh` | Amazon SNS (Simple Notification Service) | Topics inventory (subscription count per topic). |
| `sqs_report.sh` | Amazon SQS (Simple Queue Service) | Queues inventory (type, message count, visibility timeout, retention). |
| `ssm_params_report.sh` | AWS SSM Parameter Store | Parameters inventory (type, tier, version, last modified). No values exposed. |
| `stepfunctions_report.sh` | AWS Step Functions | State machines inventory (type, status, creation date, role ARN). |
| `transitgateway_report.sh` | AWS Transit Gateway | Transit Gateways inventory (state, ASN, attachment count). |
| `vpc_report.sh` | Amazon VPC (Virtual Private Cloud) | Summary of VPC resources (subnets, IGW, NAT, route tables, security groups, EIPs). |
| `vpn_report.sh` | AWS VPN (Site-to-Site VPN) | Reports on Site-to-Site VPN connections (state, gateway IDs). |
| `waf_report.sh` | AWS WAF (Web Application Firewall) | Reports on WAF Web ACLs with allowed/blocked request counts. |

## Price Optimization Reports

In addition to inventory reports, this tool includes **cost optimization analysis** scripts that analyze resource utilization and generate actionable cost-saving recommendations. All optimization reports produce CSV outputs that are combined into a **single multi-sheet Excel file** (`AWS_Optimization_Report_*.xlsx`).

### Optimization Scripts

| Script | Category | Description |
|--------|----------|-------------|
| `ec2_rightsizing_report.sh` | EC2 Right-Sizing | Identifies over-provisioned EC2 instances based on CPU/Memory utilization and recommends downsizing. |
| `rds_rightsizing_report.sh` | RDS Right-Sizing | Identifies over-provisioned RDS instances based on CPU/Memory/Storage and recommends downsizing. |
| `idle_resources_report.sh` | Idle Resources | Detects unused resources: unattached EBS, unassociated EIPs, idle Lambda/RDS/ELB. |
| `ebs_optimization_report.sh` | EBS Optimization | Recommends gp2→gp3 migration and IOPS reduction for io1/io2 volumes. |
| `ri_sp_advisor_report.sh` | RI/SP Advisor | Recommends Reserved Instance or Savings Plans purchases for consistently running instances. |
| `data_transfer_optimization_report.sh` | Data Transfer | Identifies high NAT Gateway costs and cross-region transfer patterns. |
| `s3_storage_optimization_report.sh` | S3 Storage | Recommends lifecycle policies, Intelligent-Tiering, and Glacier transitions. |
| `efs_storage_optimization_report.sh` | EFS Storage | Recommends Lifecycle Management for EFS Standard-to-IA transitions. |
| `optimization_summary_report.sh` | Summary | Aggregates all findings with total potential savings and priority classification. |

### Enabling Optimization Reports

Set the corresponding keys in `config.ini` to `1`:

```ini
; Price Optimization Reports
opt_ec2_rightsizing=1
opt_rds_rightsizing=1
opt_idle_resources=1
opt_ebs_optimization=1
opt_ri_sp_advisor=1
opt_data_transfer=1
opt_s3_storage=1
opt_efs_storage=1
opt_summary=1
```

### Configurable Thresholds

Optimization scripts support configurable thresholds via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `UTIL_THRESHOLD` | 30 | CPU/Memory % below which a resource is considered underutilized |
| `IDLE_THRESHOLD` | 5 | % below which a resource is considered idle |
| `DATA_TRANSFER_ALERT_THRESHOLD` | 100 | USD/month above which data transfer triggers a recommendation |

Example with custom thresholds:

```bash
UTIL_THRESHOLD=20 DATA_TRANSFER_ALERT_THRESHOLD=50 ./main_report_runner.sh -b 2025-08-01 -e 2025-08-31
```

### Optimization Excel Output

When at least one `opt_*` report is enabled, the tool generates a consolidated Excel file with multiple sheets:

```
AWS_Optimization_Report_my-company-prod_123456789012.xlsx
├── Summary           — Aggregated findings and total potential savings
├── EC2 Right-Sizing  — EC2 downsizing recommendations
├── RDS Right-Sizing  — RDS downsizing recommendations
├── Idle Resources    — Unused resources costing money
├── EBS Optimization  — Volume type migration and IOPS reduction
├── RI-SP Advisor     — Reserved Instance / Savings Plans recommendations
├── Data Transfer     — Network cost optimization
├── S3 Storage        — Storage class transition recommendations
└── EFS Storage       — EFS lifecycle management recommendations
```

Rows with estimated savings > $100/month are highlighted in green for quick identification.

### Pricing Data

Optimization scripts use the **AWS Pricing API** for accurate cost calculations. If the API is unavailable, they fall back to `lib/pricing_fallback.json` which contains reference pricing for common instance types in ap-southeast-1 and ap-southeast-3.

### KeepAlive Tag

Resources tagged with `KeepAlive=true` are excluded from idle resource recommendations. Use this tag to protect resources that appear idle but are intentionally kept running.

---

## Configuration

The `main_report_runner.sh` script uses the `config.ini` file to determine which reports to run. Set a report's value to `1` to enable it, or `0` to disable it.

Example `config.ini`:

```ini
; =============================================================================
; Report Configuration
; =============================================================================
; Set the value to 1 to enable a report, or 0 to disable it.
;=============================================================================

acm=1
apigateway=1
asg=1
backup=1
billing=1
cloudfront=1
cloudwatch=1
codepipeline=1
config=1
data_transfer=1
directconnect=1
dynamodb=1
ebs_detailed=1
; ebs_utilization=1
ec2=1
ecr=1
ecs=1
efs=1
eks=1
elasticache=1
elb=1
eventbridge=1
glue=1
iam=1
kinesis=1
kms=1
lambda=1
natgateway=1
opensearch=1
rds=1
redshift=1
ri=1
route53=1
s3=1
secrets_manager=1
ses=1
sns=1
sp=1
sqs=1
ssm_params=1
stepfunctions=1
transitgateway=1
vpc=1
vpn=1
waf=1
workspaces=1
; =============================================================================
; Parallel Configuration
; =============================================================================
; Set the value to 1 to enable parallel execution, or 0 to disable it.
; max_parallel controls how many report scripts run concurrently.
parallel=1
max_parallel=2
```

## Getting Started

### Prerequisites

- **AWS CLI v2** — pre-installed on AWS CloudShell
- **jq** — JSON processor (pre-installed on CloudShell)
- **bc** — calculator (pre-installed on CloudShell)
- **python3** with `pandas` and `xlsxwriter` — for CSV-to-Excel combining
- **zip** — for archiving output

### Installation

1. **Clone the Repository**:

    ```bash
    git clone https://github.com/mohamadsyalvasr/aws-cloud-utility-scripts
    cd aws-cloud-utility-scripts
    ```

2. **Make the Main Script Executable**:

    ```bash
    chmod +x main_report_runner.sh
    ```

3. **Install Python Dependencies** (if not already available):

    ```bash
    pip3 install pandas xlsxwriter
    ```

### Usage

Execute the main script with the required date range. The script will automatically run all reports enabled in `config.ini`.

```bash
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31
```

With custom regions:

```bash
./main_report_runner.sh -r ap-southeast-1,ap-southeast-3 -b 2025-08-01 -e 2025-08-31
```

### Command-Line Arguments

| Option | Description |
|--------|-------------|
| `-b <start_date>` | **REQUIRED**. Start date for utilization metrics (YYYY-MM-DD). |
| `-e <end_date>` | **REQUIRED**. End date for utilization metrics (YYYY-MM-DD). |
| `-r <regions>` | Comma-separated list of AWS regions to scan. Default: `ap-southeast-1,ap-southeast-3` |
| `-s` | Enables summation of all attached EBS volumes (applies to `aws_ec2_report.sh`). |
| `-f <filename>` | Custom filename for output reports. |
| `-h` | Display help message. |

### Output

- **Directory Structure**: Creates a folder for each run: `export/aws-cloud-report-YYYY-MM-DD/`
- **CSV Files**: Individual CSV files for each report (e.g., `aws_ec2_report.csv`, `kms_report.csv`)
- **Excel Combined**: All CSVs combined into a single Excel file: `Combined_AWS_Reports_<AccountName>_<AccountID>.xlsx`
  - Includes AWS Account info header
  - Formatted headers and borders for readability
  - Each report section clearly labeled
- **Zip Archive**: Export folder compressed into `aws_reports_YYYY-MM-DD.zip` for easy download/sharing

### Output Filename

The combined Excel file automatically includes your AWS Account Name and Account ID in the filename:

```
Combined_AWS_Reports_my-company-prod_123456789012.xlsx
```

This makes it easy to identify which account the report belongs to when managing multiple AWS accounts.

## Project Structure

```
.
├── config.ini                          # Report toggle configuration
├── main_report_runner.sh               # Main orchestrator script (modular)
├── combine_csv.py                      # Combines CSVs into Excel with account info
├── combine_optimization_excel.py       # Combines optimization CSVs into multi-sheet Excel
├── excel_styles.py                     # Excel formatting rules & conditional highlighting
├── dependencies.sh                     # Installs required dependencies
├── lib/                                # Modular libraries
│   ├── logger.sh                      # Logging functions
│   ├── task_runner.sh                 # Task execution engine (sequential/parallel)
│   ├── report_registry.sh            # Report definitions & task builder
│   ├── pricing_helper.sh             # Pricing data retrieval & caching (optimization)
│   └── pricing_fallback.json          # Reference pricing data for offline use
├── script/                             # Inventory report scripts
│   ├── acm_report.sh
│   ├── apigateway_report.sh
│   ├── ...                            # (45+ inventory report scripts)
│   └── waf_report.sh
├── script/optimization/                # Price optimization scripts
│   ├── ec2_rightsizing_report.sh
│   ├── rds_rightsizing_report.sh
│   ├── idle_resources_report.sh
│   ├── ebs_optimization_report.sh
│   ├── ri_sp_advisor_report.sh
│   ├── data_transfer_optimization_report.sh
│   ├── s3_storage_optimization_report.sh
│   ├── efs_storage_optimization_report.sh
│   └── optimization_summary_report.sh
└── web/                                # Web UI (optional)
```

## Notes

- **Modular Architecture**: `main_report_runner.sh` sources modules from `lib/`. To add a new report, just add one line to `lib/report_registry.sh` and the config key to `config.ini`.
- **CloudWatch Metrics**: Scripts that fetch utilization data (EC2, RDS, EBS, S3, WAF) require the `-b` and `-e` date arguments. CloudWatch data is sorted by timestamp to ensure the most recent datapoint is used.
- **CloudWatch Agent**: Memory utilization for EC2 and disk usage for EBS require the CloudWatch Agent to be installed on instances. If not available, these fields will show "N/A".
- **Pagination**: All scripts handle API pagination properly using `--no-paginate` to retrieve complete datasets.
- **Parallel Execution**: Enable `parallel=1` in `config.ini` to run reports concurrently. Adjust `max_parallel` to control concurrency level (recommended: 2-4 to avoid API throttling).
- **Global Services**: IAM, CloudFront, Billing, Savings Plans, and Route 53 are global APIs — they don't loop through regions.
- **Rate Limiting**: For accounts with many resources, consider keeping `max_parallel=2` to avoid AWS API throttling.
- **Excel Styling**: Conditional formatting rules are defined in `excel_styles.py`. EC2 instances not in "running" state are highlighted with background color `#DEBABA`.
- **Optimization Pricing**: The pricing helper caches API responses per execution run to minimize Pricing API calls. If the API is unreachable, fallback pricing data is used automatically.
- **Cost Explorer Access**: The RI/SP Advisor and Data Transfer optimization scripts require Cost Explorer API access. If access is denied, they log a warning and continue with other checks.

Copyright 2026

# AWS Inventory Report Generator

This repository contains a set of Bash scripts designed to automate the generation of various AWS resource inventory reports. The main script, `main_report_runner.sh`, provides a single entry point to run all reports (sequentially or in parallel), making it easy to generate comprehensive reports with a single command.

Reports are designed to run on **AWS CloudShell** or any environment with AWS CLI configured.

## Included Scripts (Alphabetical)

| Script | AWS Service | Description |
|--------|-------------|-------------|
| `asg_report.sh` | Auto Scaling Group | Reports on Auto Scaling Groups (min/max/desired capacity, instance count). |
| `aws_billing_report.sh` | AWS Billing & Cost Management | Gathers all consumed services and their costs from Cost Explorer API. |
| `aws_ec2_report.sh` | Amazon EC2 (Elastic Compute Cloud) | Detailed report on EC2 instances with specs and average CPU/Memory utilization. |
| `aws_rds_report.sh` | Amazon RDS (Relational Database Service) | Detailed report on RDS instances with specs, CPU, memory, disk, and latency metrics. |
| `aws_ri_report.sh` | EC2 Reserved Instances | Reports on purchased Reserved Instances (type, term, payment, state). |
| `aws_sp_report.sh` | AWS Savings Plans | Reports on Savings Plans (type, commitment, payment option). Global API. |
| `aws_workspaces_report.sh` | Amazon WorkSpaces | Reports on WorkSpaces (compute, volumes, running mode, last active time). |
| `cloudfront_report.sh` | Amazon CloudFront (CDN) | Reports on CloudFront Distributions. Global API. |
| `dynamodb_report.sh` | Amazon DynamoDB (NoSQL Database) | Reports on DynamoDB tables (status, item count, size). |
| `ebs_report.sh` | Amazon EBS (Elastic Block Store) | Detailed inventory of EBS volumes (type, size, IOPS, throughput, state). |
| `ebs_utilization_report.sh` | Amazon EBS (Elastic Block Store) | EBS volumes with utilization metrics (read/write bytes, disk used %). |
| `ecr_report.sh` | Amazon ECR (Elastic Container Registry) | Inventory of ECR repositories (image count, tag mutability, scan config, encryption). |
| `ecs_report.sh` | Amazon ECS (Elastic Container Service) | Reports on ECS Clusters (running/pending tasks, active services). |
| `efs_report.sh` | Amazon EFS (Elastic File System) | Reports on EFS file systems (size breakdown by storage class, state). |
| `eks_report.sh` | Amazon EKS (Elastic Kubernetes Service) | Reports on EKS clusters (version, status, creation date). |
| `elasticache_report.sh` | Amazon ElastiCache | Reports on ElastiCache clusters (node type, engine). |
| `elb_report.sh` | Elastic Load Balancing (ALB/NLB/GWLB) | Reports on all ELBv2 load balancers (type, scheme, state, DNS). |
| `iam_report.sh` | AWS IAM (Identity and Access Management) | Reports on IAM Users (create date, password last used). Global API. |
| `kms_report.sh` | AWS KMS (Key Management Service) | Inventory of KMS keys (alias, state, usage, spec, rotation status). |
| `lambda_report.sh` | AWS Lambda (Serverless Compute) | Reports on Lambda functions (runtime, handler, code size). |
| `s3_report.sh` | Amazon S3 (Simple Storage Service) | Reports on S3 buckets (object count, total size via CloudWatch). |
| `vpc_report.sh` | Amazon VPC (Virtual Private Cloud) | Summary of VPC resources (subnets, IGW, NAT, route tables, security groups, EIPs). |
| `vpn_report.sh` | AWS VPN (Site-to-Site VPN) | Reports on Site-to-Site VPN connections (state, gateway IDs). |
| `waf_report.sh` | AWS WAF (Web Application Firewall) | Reports on WAF Web ACLs with allowed/blocked request counts. |

## Configuration

The `main_report_runner.sh` script uses the `config.ini` file to determine which reports to run. Set a report's value to `1` to enable it, or `0` to disable it.

Example `config.ini`:

```ini
; =============================================================================
; Report Configuration
; =============================================================================
; Set the value to 1 to enable a report, or 0 to disable it.
;
; Each report corresponds to an AWS service:
;   asg           = Auto Scaling Group (EC2 Auto Scaling)
;   billing       = AWS Billing & Cost Management (Cost Explorer)
;   cloudfront    = Amazon CloudFront (Content Delivery Network / CDN)
;   dynamodb      = Amazon DynamoDB (NoSQL Database)
;   ebs_detailed  = Amazon EBS - Elastic Block Store (Block Storage Volumes)
;   ebs_utilization = Amazon EBS - Elastic Block Store (Utilization Metrics)
;   ec2           = Amazon EC2 - Elastic Compute Cloud (Virtual Servers)
;   ecr           = Amazon ECR - Elastic Container Registry (Docker Image Registry)
;   ecs           = Amazon ECS - Elastic Container Service (Container Orchestration)
;   efs           = Amazon EFS - Elastic File System (Managed NFS Storage)
;   eks           = Amazon EKS - Elastic Kubernetes Service (Managed Kubernetes)
;   elasticache   = Amazon ElastiCache (In-Memory Cache: Redis/Memcached)
;   elb           = Elastic Load Balancing (ALB/NLB/GWLB)
;   iam           = AWS IAM - Identity and Access Management (Users & Roles)
;   kms           = AWS KMS - Key Management Service (Encryption Key Management)
;   lambda        = AWS Lambda (Serverless Compute / Functions)
;   rds           = Amazon RDS - Relational Database Service (Managed SQL Database)
;   ri            = EC2 Reserved Instances (Discounted Capacity Reservations)
;   s3            = Amazon S3 - Simple Storage Service (Object Storage)
;   sp            = AWS Savings Plans (Flexible Pricing Discount Model)
;   vpc           = Amazon VPC - Virtual Private Cloud (Network Isolation)
;   vpn           = AWS VPN - Virtual Private Network (Site-to-Site VPN)
;   waf           = AWS WAF - Web Application Firewall (HTTP Traffic Filtering)
;   workspaces    = Amazon WorkSpaces (Managed Virtual Desktops / DaaS)
; =============================================================================

asg=1
billing=0
cloudfront=1
dynamodb=1
ebs_detailed=1
ebs_utilization=0
ec2=1
ecr=1
ecs=1
efs=0
eks=0
elasticache=0
elb=0
iam=1
kms=1
lambda=1
rds=1
ri=0
s3=1
sp=0
vpc=0
vpn=1
waf=0
workspaces=0

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
├── config.ini                  # Report toggle configuration
├── main_report_runner.sh       # Main orchestrator script
├── combine_csv.py              # Combines CSVs into Excel with account info
├── dependencies.sh             # Installs required dependencies
├── script/                     # All report scripts
│   ├── asg_report.sh
│   ├── aws_billing_report.sh
│   ├── aws_ec2_report.sh
│   ├── aws_rds_report.sh
│   ├── aws_ri_report.sh
│   ├── aws_sp_report.sh
│   ├── aws_workspaces_report.sh
│   ├── cloudfront_report.sh
│   ├── dynamodb_report.sh
│   ├── ebs_report.sh
│   ├── ebs_utilization_report.sh
│   ├── ecr_report.sh
│   ├── ecs_report.sh
│   ├── efs_report.sh
│   ├── eks_report.sh
│   ├── elasticache_report.sh
│   ├── elb_report.sh
│   ├── iam_report.sh
│   ├── kms_report.sh
│   ├── lambda_report.sh
│   ├── s3_report.sh
│   ├── vpc_report.sh
│   ├── vpn_report.sh
│   └── waf_report.sh
└── web/                        # Web UI (optional)
```

## Notes

- **CloudWatch Metrics**: Scripts that fetch utilization data (EC2, RDS, EBS, S3, WAF) require the `-b` and `-e` date arguments. CloudWatch data is sorted by timestamp to ensure the most recent datapoint is used.
- **CloudWatch Agent**: Memory utilization for EC2 and disk usage for EBS require the CloudWatch Agent to be installed on instances. If not available, these fields will show "N/A".
- **Pagination**: All scripts handle API pagination properly using `--no-paginate` to retrieve complete datasets.
- **Parallel Execution**: Enable `parallel=1` in `config.ini` to run reports concurrently. Adjust `max_parallel` to control concurrency level (recommended: 2-4 to avoid API throttling).
- **Global Services**: IAM, CloudFront, Billing, and Savings Plans are global APIs — they don't loop through regions.
- **Rate Limiting**: For accounts with many resources, consider keeping `max_parallel=2` to avoid AWS API throttling.

# AWS Inventory Report Generator

This repository contains a set of Bash scripts designed to automate the generation of various AWS resource reports. The main script, `main_report_runner.sh`, provides a single entry point to run all reports sequentially, making it easy to generate comprehensive reports with a single command.

## Included Scripts

- **`aws_billing_report.sh`**: Gathers all consumed services and their costs for a specified time period directly from the AWS Billing and Cost Management API.
- **`aws_ec2_report.sh`**: Generates a detailed report on EC2 instances, including specifications and average utilization metrics.
- **`aws_rds_report.sh`**: Generates a detailed report on RDS instances, including specifications and average utilization metrics.
- **`aws_ri_report.sh`**: Generates a detailed report on AWS Reserved Instances (RI).
- **`aws_sp_report.sh`**: Generates a detailed report on AWS Savings Plans.
- **`aws_workspaces_report.sh`**: Gathers a detailed report on AWS WorkSpaces, including last active time.
- **`ebs_report.sh`**: Generates a detailed report on EBS volumes with custom columns.
- **`ebs_utilization_report.sh`**: Generates a report on EBS volumes, showing attachment status, disk size, and utilization metrics.
- **`efs_report.sh`**: Generates a detailed report on all EFS file systems, including size and status details.
- **`eks_report.sh`**: Generates a detailed report on all EKS clusters and saves it to an output directory.
- **`elasticache_report.sh`**: Generates a detailed report on all ElastiCache clusters and saves it to an output directory.
- **`elb_report.sh`**: Generates a detailed report on all Elastic Load Balancers (ELBv2: ALB/NLB/GWLB) across regions into a CSV.
- **`s3_report.sh`**: Generates a detailed report on all S3 buckets, using CloudWatch to get the total size.
- **`vpc_report.sh`**: Generates a summary report of VPC-related services and their quantities (per region).
- **`waf_report.sh`**: Generates a detailed report on all AWS WAF Web ACLs, including allowed and blocked requests.
- **`iam_report.sh`**: (NEW) Gathers a report on IAM Users (Global).
- **`lambda_report.sh`**: (NEW) Gathers a report on Lambda functions.
- **`cloudfront_report.sh`**: (NEW) Gathers a report on CloudFront Distributions (Global).
- **`dynamodb_report.sh`**: (NEW) Gathers a report on DynamoDB tables.
- **`asg_report.sh`**: (NEW) Gathers a report on Auto Scaling Groups.
- **`ecs_report.sh`**: (NEW) Gathers a report on ECS Clusters and Services.
- **`vpn_report.sh`**: (NEW) Gathers a report on Site-to-Site VPN connections.

## Configuration

The `main_report_runner.sh` script uses the `config.ini` file to determine which reports to run. To enable a report, set its value to `1`. To disable it, set the value to `0`.

Example `config.ini`:

```
; Report Configuration
; Set the value to 1 to enable a report, or 0 to disable it.
; You can use the main_report_runner.sh script to run these reports.

billing=0
ebs_detailed=1
ebs_utilization=0
ec2=1
rds=1
efs=0
eks=0
elasticache=0
elb=0
s3=1
sp=0
ri=0
vpc=0
waf=0
workspaces=0
iam=1
lambda=1
cloudfront=1
dynamodb=1
asg=1
ecs=1
vpn=1

```

## Getting Started

1. **Clone the Repository**:
    
    ```
    git clone https://github.com/mohamadsyalvasr/aws-cloud-utility-scripts
    
    ```
    
2. **Make the Main Script Executable**:
You only need to do this once after cloning. The main script will handle setting permissions for the other scripts.
    
    ```
    chmod +x main_report_runner.sh
    
    ```
    
3. **Run the Report Generator**:
Execute the main script with the required date range. The script will automatically run all scripts enabled in `config.ini`.
    
    ```
    ./main_report_runner.sh -r ap-southeast-1,ap-southeast-3 -b 2025-08-01 -e 2025-08-31
    
    ```
    

### Command-Line Arguments

The `main_report_runner.sh` script accepts the following arguments, which it will intelligently pass to the relevant sub-scripts.

| Option | Description |
| --- | --- |
| `-b <start_date>` | **REQUIRED**: The start date for utilization metrics (YYYY-MM-DD). |
| `-e <end_date>` | **REQUIRED**: The end date for utilization metrics (YYYY-MM-DD). |
| `-r <regions>` | A comma-separated list of AWS regions to scan. |
| `-s` | Enables the summation of all attached EBS volumes. (Only applies to scripts that support it, such as `aws_ec2_report.sh` and `aws_ec2_rds.sh`). |
| `-f <filename>` | Specifies a custom filename for the output reports. |
| `-h` | Displays a help message. |

### Output

-   **Directory Structure**: The script creates a dedicated folder for each day's run: `export/aws-cloud-report-YYYY-MM-DD/`.
-   **Files**: Inside this folder, you will find individual CSV files for each generated report (e.g., `aws_ec2_report.csv`, `iam_report.csv`).
-   **Excel Combine**: The script automatically combines all generated CSV files into a single Excel file named `Combined_AWS_Reports.xlsx` within the same export folder. This Excel file includes formatted headers and borders for better readability.
-   **Zip Archive**: Finally, the export folder is compressed into a ZIP file (e.g., `aws_reports_2025-08-01.zip`) in the current directory for easy sharing.

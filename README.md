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

The script will create a date-based output directory and save all CSV report files within it. After all reports are generated, the script will compress the output folder into a single ZIP file.

Example ZIP file name: `aws_reports_2025-09-04.zip`.

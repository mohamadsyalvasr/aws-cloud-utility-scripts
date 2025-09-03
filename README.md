# AWS Combined Report Generator

This repository contains a set of Bash scripts designed to automate the generation of various AWS resource reports. The main script, `main_report_runner.sh`, provides a single entry point to run all reports sequentially, making it easy to generate comprehensive reports with one command.

## Scripts Included

- **`aws_inventory.sh`**: Generates a detailed inventory of EC2 and RDS instances, including specifications and average utilization metrics for a specified time period.
- **`ebs_report.sh`**: Creates a report on EBS volumes, showing attachment status, disk size, and utilization metrics (if CloudWatch Agent is configured).
- **`aws_sp_ri_report.sh`**: Generates a combined report of Savings Plans (SP) and Reserved Instances (RI), useful for cost and capacity management.

## Getting Started
### Usage

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
Execute the main script with the required date range. The script will automatically run the three sub-scripts and save the results in the current directory.
    
    ```
    ./main_report_runner.sh -r ap-southeast-1,ap-southeast-3 -b 2025-08-01 -e 2025-08-31
    
    ```
    

### Command-Line Arguments

The `main_report_runner.sh` script accepts the following arguments, which it will intelligently pass to the relevant sub-scripts.

| Option | Description |
| --- | --- |
| `-b <start_date>` | **REQUIRED**: The start date for utilization metrics (YYYY-MM-DD). |
| `-e <end_date>` | **REQUIRED**: The end date for utilization metrics (YYYY-MM-DD). |
| `-r <regions>` | Comma-separated list of AWS regions to scan. |
| `-s` | Enables summation of all attached EBS volumes. (Applies only to `aws_inventory.sh` and `ebs_report.sh`). |
| `-f <filename>` | Specifies a custom filename for the output reports. |
| `-h` | Displays a help message. |

### Output

The script will generate three separate CSV files:

- `aws_inventory_<timestamp>.csv`
- `ebs_report_<timestamp>.csv`
- `aws_sp_ri_report.csv`

Each file is formatted for easy viewing in spreadsheet applications.

# AWS Cloud Utility Scripts

A comprehensive toolkit for AWS infrastructure **inventory reporting**, **cost optimization**, and **security auditing**. Run from AWS CloudShell or any environment with AWS CLI configured.

## Features

| Mode | Description | Flag |
|------|-------------|------|
| **Inventory** | Generate detailed CSV/Excel reports for 50+ AWS services | `--mode inventory` |
| **Optimize** | Analyze resource utilization and recommend cost savings | `--mode optimize` |
| **Security** | Audit security configurations and compliance *(coming soon)* | `--mode security` |

All modes can be combined: `--mode optimize,security`

## Quick Start

```bash
# Clone
git clone https://github.com/mohamadsyalvasr/aws-cloud-utility-scripts
cd aws-cloud-utility-scripts

# Make the Main Script Executable
chmod +x main_report_runner.sh

# Run all enabled reports
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31

# Run only optimization reports
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m optimize

# Run optimization + security
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m optimize,security
```

## Command-Line Options

| Option | Description |
|--------|-------------|
| `-b <date>` | **Required.** Start date (YYYY-MM-DD) |
| `-e <date>` | **Required.** End date (YYYY-MM-DD) |
| `-r <regions>` | Comma-separated regions. Default: `ap-southeast-1,ap-southeast-3` |
| `-m <mode>` | Run mode: `all`, `inventory`, `optimize`, `security` (comma-separated) |
| `-s` | Sum attached EBS volumes in EC2 report |
| `-f <filename>` | Custom output filename |
| `-h` | Show help |

## Configuration

Edit `config.ini` to enable/disable individual reports:

```ini
# Inventory reports (no prefix)
ec2=1
rds=1
s3=1

# Optimization reports (opt_ prefix)
opt_ec2_rightsizing=1
opt_idle_resources=1
opt_s3_storage=1
opt_summary=1

# Security reports (sec_ prefix) — coming soon
# sec_iam_audit=1
# sec_sg_check=1

# Parallel execution
parallel=1
max_parallel=2
```

## Output

```
export/aws-cloud-report-2025-08-31/
├── *.csv                                          # Individual report CSVs
├── Combined_AWS_Reports_<Account>.xlsx            # Inventory Excel (all reports in one sheet)
└── AWS_Optimization_Report_<Account>.xlsx         # Optimization Excel (multi-sheet)

aws_reports_2025-08-31.zip                         # Everything zipped
```

## Documentation

Detailed documentation is available in the [`docs/`](docs/) folder:

| Document | Description |
|----------|-------------|
| [Inventory Reports](docs/inventory-reports.md) | Full list of 50+ inventory scripts with columns and details |
| [Price Optimization](docs/price-optimization.md) | How optimization works, thresholds, pricing data, recommendations |
| [Configuration Guide](docs/configuration.md) | All config.ini options, environment variables, and modes |
| [Adding New Reports](docs/adding-reports.md) | How to add your own report scripts to the framework |

## Project Structure

```
.
├── main_report_runner.sh               # Main orchestrator
├── config.ini                          # Report toggles
├── combine_csv.py                      # Inventory → Excel
├── combine_optimization_excel.py       # Optimization → multi-sheet Excel
├── excel_styles.py                     # Excel formatting
├── lib/                                # Shared libraries
│   ├── logger.sh                      #   Logging
│   ├── task_runner.sh                 #   Sequential/parallel execution
│   ├── report_registry.sh            #   Report definitions & mode filtering
│   ├── pricing_helper.sh             #   AWS Pricing API + cache
│   └── pricing_fallback.json          #   Offline pricing reference
├── script/                             # Inventory reports (50+ scripts)
├── script/optimization/                # Cost optimization reports
├── docs/                               # Documentation
└── web/                                # Web UI (optional)
```

## Prerequisites

- **AWS CLI v2** — pre-installed on CloudShell
- **jq** — JSON processor
- **bc** — calculator
- **python3** + `pandas` + `xlsxwriter`
- **zip** — for archiving

## License

Copyright 2026

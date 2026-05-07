# AWS Cloud Utility Scripts

A comprehensive toolkit for AWS infrastructure **inventory reporting**, **cost optimization**, and **security auditing**. Run from AWS CloudShell or any environment with AWS CLI configured.

## Prerequisites

- **AWS CLI v2** — pre-installed on CloudShell
- **jq** — JSON processor
- **bc** — calculator
- **python3** + `pandas` + `xlsxwriter`
- **zip** — for archiving

## Features

| Mode | Description | Flag |
|------|-------------|------|
| **Inventory** | Generate detailed CSV/Excel reports for 60+ AWS services | `--mode inventory` |
| **Optimize** | Analyze resource utilization and recommend cost savings | `--mode optimize` |
| **Security** | Audit security configurations and compliance | `--mode security` |

All modes can be combined: `--mode optimize,security`

## Quick Start

```bash
# Clone
git clone https://github.com/mohamadsyalvasr/aws-cloud-utility-scripts
cd aws-cloud-utility-scripts

# Option 1: Interactive TUI (recommended for first-time users)
chmod +x launcher.sh
./launcher.sh

# Option 2: CLI with flags
chmod +x main_report_runner.sh
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31

# Auto-discover: only report services that appear in your billing
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 --auto-discover

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
| `-a, --auto-discover` | Auto-enable reports based on billing data (requires Cost Explorer access) |
| `--excel-mode <mode>` | Excel output: `single` (1 sheet) or `multi` (1 sheet per service). Default: `single` |
| `-s` | Sum attached EBS volumes in EC2 report |
| `-f <filename>` | Custom output filename |
| `-h` | Show help |

### Excel Output Modes

| Run Mode | Excel Behavior |
|----------|---------------|
| `--mode all` | **Automatic**: 1 file with 3 sheets — Inventory, Optimization, Security |
| `--mode inventory` | Default: 1 sheet. With `--excel-mode multi`: 1 sheet per AWS service |
| `--mode optimize` | Always multi-sheet (1 sheet per optimization category) |
| `--mode security` | Always multi-sheet (1 sheet per security category) |

```bash
# Mode all → 3 sheets grouped by type
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31

# Inventory with 1 sheet per service
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m inventory --excel-mode multi
```

### Auto-Discovery Mode

When using `--auto-discover`, the tool queries Cost Explorer to automatically detect:
1. **Which services** are active (have non-zero cost) → enables only those reports
2. **Which regions** have resources (have non-zero cost) → scans only those regions

```bash
# Full auto: services + regions detected from billing
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 --auto-discover

# Auto services, but override regions manually
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -a -r us-east-1,eu-west-1
```

Example output:
```
[10:30:01] 🔍 Auto-discovering active services from billing data...
[10:30:03] ✅ Auto-discovery complete: 12 report(s) enabled
[10:30:03]    Enabled: acm cloudwatch ec2 ebs_detailed elb iam lambda rds s3 sns sqs vpc
[10:30:03]
[10:30:03]    ⚠️  Services found in billing but NO report script available:
[10:30:03]      • AWS Support (Business)
[10:30:03]      • Tax
[10:30:03]
[10:30:03] 🌍 Auto-discovering active regions from billing data...
[10:30:04] ✅ Region discovery complete: 3 region(s) found
[10:30:04]    Regions: ap-southeast-1,ap-southeast-3,us-east-1
```

**Notes:**
- If you pass `-r` explicitly, region auto-discovery is skipped and your specified regions are used instead.
- Auto-discovery works for **inventory** and **optimization** modes. For `--mode security`, reports must be selected manually.
- Optimization mapping: EC2 in billing → enables `opt_ec2_rightsizing`, RDS → `opt_rds_rightsizing`, etc.
- Services like Tax, CloudShell, and Amplify are recognized but intentionally skipped (no report needed).

This helps you identify gaps — services you're paying for but don't have visibility into.

## Interactive Launcher (TUI)

For users who prefer a guided experience, use the interactive launcher:

```bash
./launcher.sh
```

The launcher uses `whiptail` (pre-installed on AWS CloudShell and most Linux distros) to provide a terminal GUI with:

1. **Welcome screen** — overview of what the tool does
2. **Mode selection** — radio buttons for inventory/optimize/security/all
3. **Report selection method** — auto-discover from billing, manual checklist, or use config.ini
4. **Date range input** — start and end dates with defaults (last 30 days)
5. **Region input** — comma-separated regions
6. **Execution mode** — parallel or sequential
7. **Report checklist** — checkboxes to toggle individual reports (if manual mode)
8. **Confirmation** — review settings and execute

```
┌─────────── Report Selection Method ─────────────┐
│                                                  │
│  (*) Auto-discover from billing (recommended)    │
│  ( ) Manual selection from checklist             │
│  ( ) Use config.ini as-is                        │
│                                                  │
│           <OK>        <Cancel>                   │
└──────────────────────────────────────────────────┘
```

**Prerequisite:** `whiptail` — if not available, the script shows install instructions and suggests using the CLI directly.

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

# Security reports (sec_ prefix)
sec_trusted_advisor=1
sec_iam_audit=1
sec_sg_audit=1
sec_encryption_audit=1
sec_summary=1

# Parallel execution
parallel=1
max_parallel=2
```

## Output

```
export/aws-cloud-report-2025-08-31/
├── *.csv                                          # Individual report CSVs
├── Combined_AWS_Reports_<Account>.xlsx            # Inventory Excel (all reports in one sheet)
├── AWS_Optimization_Report_<Account>.xlsx         # Optimization Excel (multi-sheet)
└── AWS_Security_Report_<Account>.xlsx             # Security Excel (multi-sheet, severity color-coded)

aws_reports_2025-08-31.zip                         # Everything zipped
```

## Additional Features

| Feature | Description | Script/Config |
|---------|-------------|---------------|
| **Tagging Compliance** | Check resources for mandatory tags (configurable via `MANDATORY_TAGS` env var) | `tagging_compliance=1` |
| **Resource Lifecycle** | Identify stale AMIs, deprecated runtimes, outdated EKS versions | `resource_lifecycle=1` |
| **Cost Trend Analysis** | Compare costs between periods, highlight services with >20% increase | `opt_cost_trend=1` |
| **Multi-Account** | Run reports across multiple AWS accounts via cross-account roles | `./multi_account_runner.sh` |
| **Compliance Scorecard** | Executive summary with Health Score (0-100) aggregating all reports | `scorecard=1` |
| **Delta Report** | Compare current run vs baseline — detect NEW/REMOVED/CHANGED resources | `delta_report=1` |
| **Notifications** | Send summary to Slack, Teams, or Email (SNS) after reports complete | `NOTIFY_SLACK=1` env var |

## Documentation

Detailed documentation is available in the [`docs/`](docs/) folder:

| Document | Description |
|----------|-------------|
| [Inventory Reports](docs/inventory-reports.md) | Full list of 60+ inventory scripts with columns and details |
| [Price Optimization](docs/price-optimization.md) | How optimization works, thresholds, pricing data, recommendations |
| [Security Audit](docs/security-audit.md) | How security auditing works, Trusted Advisor integration, severity levels |
| [Multi-Account Setup](docs/multi-account-setup.md) | Prerequisites for cross-account reporting (IAM roles, trust policies) |
| [Configuration Guide](docs/configuration.md) | All config.ini options, environment variables, and modes |
| [Adding New Reports](docs/adding-reports.md) | How to add your own report scripts to the framework |

## Project Structure

```
.
├── main_report_runner.sh               # Main orchestrator (CLI)
├── launcher.sh                         # Interactive TUI launcher (whiptail)
├── multi_account_runner.sh             # Multi-account wrapper (standalone)
├── accounts.conf                       # Multi-account target list
├── config.ini                          # Report toggles
├── lib/                                # Shared libraries
│   ├── python/                        #   Python Excel combiners
│   │   ├── combine_csv.py            #     Inventory → Excel
│   │   ├── combine_optimization_excel.py  #  Optimization → multi-sheet Excel
│   │   ├── combine_security_excel.py #     Security → multi-sheet Excel
│   │   └── excel_styles.py           #     Shared Excel formatting
│   ├── logger.sh                      #   Logging
│   ├── task_runner.sh                 #   Sequential/parallel execution
│   ├── report_registry.sh            #   Report definitions & mode filtering
│   ├── pricing_helper.sh             #   AWS Pricing API + cache
│   ├── pricing_fallback.json          #   Offline pricing reference
│   └── notifier.sh                    #   Slack/Teams/SNS notifications
├── script/
│   ├── inventory/                      # Inventory reports (60+ scripts)
│   ├── optimization/                   # Cost optimization reports
│   ├── security/                       # Security audit reports
│   └── compliance/                     # Compliance & governance reports
├── docs/                               # Documentation
└── web/                                # Web UI (optional)
```

## License

Copyright 2026

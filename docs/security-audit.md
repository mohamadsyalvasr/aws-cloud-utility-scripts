# Security Audit

The security audit module identifies misconfigurations, compliance gaps, and vulnerabilities across your AWS infrastructure. It uses a **"Trusted Advisor First"** approach for efficiency.

## How It Works

```
1. Try Trusted Advisor (security category)
   ├── Available? → Use TA findings for IAM, SG, S3, Logging
   └── Not available? → Fall back to manual checks for all categories

2. Always run manual checks for categories TA doesn't cover:
   - Encryption (EBS/RDS/KMS)
   - Network Security (VPC flow logs, public subnets)
   - Security Hub (active findings)

3. Combine all findings → Summary → Excel
```

### Why Trusted Advisor First?

- **Faster**: TA findings are pre-computed by AWS — no need to query CloudWatch per resource
- **Cheaper**: Fewer API calls = less chance of throttling
- **Comprehensive**: TA checks things that are hard to replicate manually (e.g., cross-account access patterns)

**Requirement**: Business or Enterprise Support plan. If unavailable, all manual fallback scripts run automatically.

## Security Scripts

| Script | Category | Coverage Check | What It Audits |
|--------|----------|---------------|----------------|
| `sec_trusted_advisor.sh` | Orchestrator | N/A (runs first) | Pulls all TA security findings, writes `.ta_coverage` |
| `sec_iam_audit.sh` | IAM | ✅ Checks TA | MFA, admin access, stale keys, root usage, password policy |
| `sec_sg_audit.sh` | Security Groups | ✅ Checks TA | Open SSH/RDP, all-traffic, any-port, egress, unused SGs |
| `sec_s3_audit.sh` | S3 Buckets | ✅ Checks TA | Public access block, encryption, logging, public policies |
| `sec_logging_audit.sh` | Logging | ✅ Checks TA | CloudTrail, GuardDuty, AWS Config |
| `sec_encryption_audit.sh` | Encryption | ❌ Always runs | Unencrypted EBS/RDS, KMS key rotation |
| `sec_network_audit.sh` | Network | ❌ Always runs | VPC flow logs, default VPC, public subnets |
| `sec_securityhub.sh` | Security Hub | ❌ Always runs | Active findings (NEW/NOTIFIED, limit 500/region) |
| `sec_summary_report.sh` | Summary | ❌ Always runs | Aggregates all findings by severity |

## Coverage Map (`.ta_coverage`)

The orchestrator writes a `.ta_coverage` file in the output directory listing which categories Trusted Advisor covered:

```
# Written by sec_trusted_advisor.sh at 2025-08-31 10:30:00
# Categories with Trusted Advisor coverage
IAM
SG
S3
LOGGING
```

Fallback scripts check this file at startup. If their category is listed, they skip (write header-only CSV and exit 0).

## Severity Levels

| Severity | Color (Excel) | Examples |
|----------|--------------|----------|
| **Critical** | Red (#FFC7CE) | SSH open to world, root account used, no CloudTrail, public S3 policy |
| **High** | Orange (#FCD5B4) | No MFA, unencrypted EBS/RDS, GuardDuty disabled, public access block missing |
| **Medium** | Yellow (#FFEB9C) | Stale access keys, no S3 logging, no VPC flow logs, KMS rotation off |
| **Low** | Blue (#BDD7EE) | Unrestricted egress, default VPC in use, unused security groups |

## Excel Output

When security reports run, a multi-sheet Excel file is generated:

| Sheet | Content |
|-------|---------|
| Summary | Findings count by category and severity, with TOTAL row |
| Trusted Advisor | Findings pulled directly from TA |
| IAM Audit | IAM security findings |
| Security Groups | SG rule violations |
| S3 Buckets | S3 security findings |
| Encryption | Unencrypted resources |
| Network Security | VPC/subnet findings |
| Logging & Monitoring | CloudTrail/GuardDuty/Config findings |
| Security Hub | Active Security Hub findings |

## CSV Format

All security CSVs use a unified 6-column format:

```csv
"Finding","Resource","Detail","Severity","Recommendation","Region"
"SSH open to world","sg-0abc123","SG my-sg allows SSH from 0.0.0.0/0","Critical","Restrict SSH to specific IPs","ap-southeast-1"
```

## Configuration

```ini
; Security Audit Reports
sec_trusted_advisor=1    ; Primary source (requires Business/Enterprise support)
sec_iam_audit=1          ; IAM security (fallback if TA unavailable)
sec_sg_audit=1           ; Security Groups (fallback if TA unavailable)
sec_s3_audit=1           ; S3 bucket security (fallback if TA unavailable)
sec_encryption_audit=1   ; Encryption audit (always manual)
sec_network_audit=1      ; Network security (always manual)
sec_logging_audit=1      ; Logging & monitoring (fallback if TA unavailable)
sec_securityhub=1        ; Security Hub findings (always manual)
sec_summary=1            ; Aggregated summary
```

## Usage

```bash
# Security audit only
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m security

# Security + Optimization
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31 -m optimize,security

# Everything
./main_report_runner.sh -b 2025-08-01 -e 2025-08-31
```

## AWS Permissions Required

Security audit scripts need these additional permissions beyond `ReadOnlyAccess`:

| Permission | Used By |
|-----------|---------|
| `support:DescribeTrustedAdvisor*` | Trusted Advisor integration |
| `securityhub:GetFindings` | Security Hub integration |
| `guardduty:ListDetectors` | GuardDuty check |
| `config:DescribeConfigurationRecorders` | AWS Config check |
| `iam:GenerateCredentialReport` | Root account usage check |
| `iam:GetCredentialReport` | Root account usage check |

## Execution Order

The scripts execute in this guaranteed order (sequential mode):

1. `sec_trusted_advisor.sh` — writes `.ta_coverage`
2. `sec_iam_audit.sh` — checks coverage, skips or runs
3. `sec_sg_audit.sh` — checks coverage, skips or runs
4. `sec_s3_audit.sh` — checks coverage, skips or runs
5. `sec_encryption_audit.sh` — always runs
6. `sec_network_audit.sh` — always runs
7. `sec_logging_audit.sh` — checks coverage, skips or runs
8. `sec_securityhub.sh` — always runs
9. `sec_summary_report.sh` — aggregates all findings

**Important**: If `parallel=1` is enabled in config.ini, the coverage map mechanism may not work correctly because fallback scripts could run before the orchestrator finishes. For security mode, sequential execution is recommended.

## Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| All scripts run manually despite TA being available | `.ta_coverage` file empty or missing | Check if `sec_trusted_advisor` is enabled and runs first |
| "SubscriptionRequiredException" | No Business/Enterprise support | Expected — manual fallbacks will run |
| Security Hub returns no findings | Security Hub not enabled | Enable Security Hub in the AWS console |
| GuardDuty "not available" | Region doesn't support GuardDuty | Normal — script skips that region |

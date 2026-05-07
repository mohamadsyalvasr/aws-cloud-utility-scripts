"""
combine_security_excel.py
Generates a single Excel workbook with multiple sheets — one sheet per
security audit category plus a summary sheet. Applies severity-based
conditional formatting.

Usage:
    python3 combine_security_excel.py <csv_directory> [--skip-aws-info]

Output:
    AWS_Security_Report_<AccountName>_<AccountID>.xlsx
"""

import pandas as pd
import os
import sys
import subprocess


# =============================================================================
# Sheet mapping: CSV filename -> Excel sheet name
# =============================================================================
SHEET_MAPPING = [
    ("sec_summary_report.csv", "Summary"),
    ("sec_trusted_advisor.csv", "Trusted Advisor"),
    ("sec_iam_audit.csv", "IAM Audit"),
    ("sec_sg_audit.csv", "Security Groups"),
    ("sec_s3_audit.csv", "S3 Buckets"),
    ("sec_encryption_audit.csv", "Encryption"),
    ("sec_network_audit.csv", "Network Security"),
    ("sec_logging_audit.csv", "Logging & Monitoring"),
    ("sec_securityhub.csv", "Security Hub"),
]


# =============================================================================
# AWS Account Info (reused pattern from combine_optimization_excel.py)
# =============================================================================

def get_aws_account_info():
    """
    Retrieve Account ID and Account Name (alias) from AWS CLI.
    Returns tuple (account_id, account_name).
    """
    account_id = "UnknownAccountID"
    account_name = ""

    try:
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            account_id = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"Warning: Failed to retrieve Account ID. {e}")

    try:
        result = subprocess.run(
            ["aws", "iam", "list-account-aliases", "--query", "AccountAliases[0]", "--output", "text"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip() and result.stdout.strip() != "None":
            account_name = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"Warning: Failed to retrieve Account Alias. {e}")

    return account_id, account_name


# =============================================================================
# Excel Formats
# =============================================================================

def get_security_formats(workbook):
    """
    Returns a dictionary of all formats used in the security Excel report.
    Includes severity-based conditional formatting.
    """
    formats = {
        # Account info header
        'account_info': workbook.add_format({
            'bold': True, 'font_size': 12,
            'bg_color': '#4472C4', 'font_color': '#FFFFFF', 'border': 1
        }),
        # Table header (column names)
        'table_header': workbook.add_format({
            'bold': True, 'border': 1, 'bg_color': '#F2F2F2'
        }),
        # No. column header
        'no_header': workbook.add_format({
            'bold': True, 'border': 1, 'bg_color': '#F2F2F2', 'align': 'center'
        }),
        # Regular data cell
        'data': workbook.add_format({'border': 1}),
        # No. column data
        'no': workbook.add_format({'border': 1, 'align': 'center'}),
        # Severity: Critical - red background, bold
        'severity_critical': workbook.add_format({
            'border': 1, 'bg_color': '#FFC7CE', 'bold': True
        }),
        'no_severity_critical': workbook.add_format({
            'border': 1, 'align': 'center', 'bg_color': '#FFC7CE', 'bold': True
        }),
        # Severity: High - orange background
        'severity_high': workbook.add_format({
            'border': 1, 'bg_color': '#FCD5B4'
        }),
        'no_severity_high': workbook.add_format({
            'border': 1, 'align': 'center', 'bg_color': '#FCD5B4'
        }),
        # Severity: Medium - yellow background
        'severity_medium': workbook.add_format({
            'border': 1, 'bg_color': '#FFEB9C'
        }),
        'no_severity_medium': workbook.add_format({
            'border': 1, 'align': 'center', 'bg_color': '#FFEB9C'
        }),
        # Severity: Low - light blue background
        'severity_low': workbook.add_format({
            'border': 1, 'bg_color': '#BDD7EE'
        }),
        'no_severity_low': workbook.add_format({
            'border': 1, 'align': 'center', 'bg_color': '#BDD7EE'
        }),
        # Summary total row - bold with blue background
        'summary_total': workbook.add_format({
            'bold': True, 'border': 1, 'bg_color': '#BDD7EE'
        }),
        'no_summary_total': workbook.add_format({
            'bold': True, 'border': 1, 'align': 'center', 'bg_color': '#BDD7EE'
        }),
    }
    return formats


# =============================================================================
# Severity Column Detection
# =============================================================================

def find_severity_column_index(columns):
    """
    Find the index of the Severity column in the DataFrame columns.
    """
    for idx, col in enumerate(columns):
        if col.strip().lower() == 'severity':
            return idx
    return None


def get_severity_value(row_data, severity_idx):
    """
    Extract severity string from a row.
    Returns empty string if not found.
    """
    if severity_idx is None or severity_idx >= len(row_data):
        return ""
    val = str(row_data[severity_idx]).strip()
    return val


# =============================================================================
# Sheet Writing
# =============================================================================

def write_security_sheet(workbook, sheet_name, df, fmt, display_label, is_summary=False):
    """
    Write a single security category sheet with formatted headers,
    borders, severity-based conditional highlighting, and auto-fit column widths.
    """
    worksheet = workbook.add_worksheet(sheet_name)

    # Row 0: Account info header
    worksheet.write(0, 0, f"AWS Account: {display_label}", fmt['account_info'])

    # Row 2: Column headers (bold, gray background)
    header_row = 2
    worksheet.write(header_row, 0, "No.", fmt['no_header'])
    columns = df.columns.tolist()
    for col_num, col_name in enumerate(columns):
        worksheet.write(header_row, col_num + 1, col_name, fmt['table_header'])

    # Find severity column for conditional highlighting
    severity_idx = find_severity_column_index(columns)

    # Row 3+: Data rows with No. column prepended
    data_rows = df.fillna('').values.tolist()
    current_row = header_row + 1

    # Track max column widths for auto-fit
    col_widths = [5]  # No. column width
    for col_name in columns:
        col_widths.append(max(len(str(col_name)), 8))

    for row_idx, row_data in enumerate(data_rows, start=1):
        severity_val = get_severity_value(row_data, severity_idx)

        # Determine row format based on severity or summary total
        is_total_row = False
        if is_summary and len(row_data) > 0:
            first_cell = str(row_data[0]).strip().upper()
            if first_cell in ('TOTAL', 'TOTALS'):
                is_total_row = True

        if is_total_row:
            no_fmt = fmt['no_summary_total']
            data_fmt = fmt['summary_total']
        elif severity_val.lower() == 'critical':
            no_fmt = fmt['no_severity_critical']
            data_fmt = fmt['severity_critical']
        elif severity_val.lower() == 'high':
            no_fmt = fmt['no_severity_high']
            data_fmt = fmt['severity_high']
        elif severity_val.lower() == 'medium':
            no_fmt = fmt['no_severity_medium']
            data_fmt = fmt['severity_medium']
        elif severity_val.lower() == 'low':
            no_fmt = fmt['no_severity_low']
            data_fmt = fmt['severity_low']
        else:
            no_fmt = fmt['no']
            data_fmt = fmt['data']

        # Write No. column
        worksheet.write(current_row, 0, row_idx, no_fmt)

        # Write data columns
        for col_num, value in enumerate(row_data):
            worksheet.write(current_row, col_num + 1, value, data_fmt)
            # Track column width
            val_len = len(str(value)) if value != '' else 0
            if col_num + 1 < len(col_widths):
                col_widths[col_num + 1] = max(col_widths[col_num + 1], val_len)
            else:
                col_widths.append(max(val_len, 8))

        current_row += 1

    # Auto-fit column widths (cap at 50 characters)
    for col_idx, width in enumerate(col_widths):
        adjusted_width = min(width + 2, 50)
        worksheet.set_column(col_idx, col_idx, adjusted_width)

    return worksheet


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 2:
        print("Error: Please provide the CSV directory path as an argument.")
        print("Usage: python3 combine_security_excel.py <csv_directory> [--skip-aws-info]")
        sys.exit(1)

    csv_directory = sys.argv[1]
    skip_aws_info = "--skip-aws-info" in sys.argv

    # Get AWS Account Info
    if skip_aws_info:
        account_id = "NoAccount"
        account_name = ""
        print("Skipping AWS account info lookup (--skip-aws-info flag).")
    else:
        print("Retrieving AWS Account information...")
        account_id, account_name = get_aws_account_info()
        print(f"  Account ID   : {account_id}")
        print(f"  Account Name : {account_name if account_name else '(no alias)'}")

    # Determine display label and safe filename
    if not account_name or account_name == account_id:
        display_label = account_id
        safe_filename_part = account_id
    else:
        display_label = f"{account_name} ({account_id})"
        safe_filename_part = f"{account_name}_{account_id}"

    # Sanitize for filename
    safe_filename_part = "".join(
        c if c.isalnum() or c in ("-", "_") else "_" for c in safe_filename_part
    )

    output_filename = os.path.join(
        csv_directory,
        f"AWS_Security_Report_{safe_filename_part}.xlsx"
    )

    # Scan for available security CSV files
    available_sheets = []
    for csv_filename, sheet_name in SHEET_MAPPING:
        csv_path = os.path.join(csv_directory, csv_filename)
        if os.path.isfile(csv_path):
            try:
                df = pd.read_csv(csv_path, encoding='utf-8')
            except UnicodeDecodeError:
                df = pd.read_csv(csv_path, encoding='latin-1')
            except pd.errors.EmptyDataError:
                print(f"  Skipping empty CSV file: {csv_filename}")
                continue

            # Skip CSVs with header only (no data rows)
            if df.shape[0] == 0:
                print(f"  Skipping '{csv_filename}' (no data, header only)")
                continue

            available_sheets.append((csv_filename, sheet_name, df))

    if not available_sheets:
        print(f"Warning: No security CSV files with data found in: {csv_directory}")
        print("Expected files: " + ", ".join(f[0] for f in SHEET_MAPPING))
        return

    print(f"\nCreating security Excel report with {len(available_sheets)} sheets...")
    print(f"Output: {output_filename}\n")

    try:
        with pd.ExcelWriter(output_filename, engine='xlsxwriter') as writer:
            workbook = writer.book
            fmt = get_security_formats(workbook)

            for csv_filename, sheet_name, df in available_sheets:
                is_summary = (sheet_name == "Summary")
                write_security_sheet(
                    workbook, sheet_name, df, fmt, display_label, is_summary=is_summary
                )
                print(f"  Added sheet '{sheet_name}' ({df.shape[0]} rows from {csv_filename})")

        print(f"\nDone! File saved: {output_filename}")

    except Exception as e:
        print(f"Error: Failed to create Excel file. {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()

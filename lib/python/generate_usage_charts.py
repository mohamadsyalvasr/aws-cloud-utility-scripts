"""
generate_usage_charts.py
Generates charts (PNG) and Excel report from Bedrock token usage data,
then packages everything into a ZIP file.

Usage:
    python3 generate_usage_charts.py <output_dir> <bedrock_csv> <agents_csv> <timeseries_json> <start_date> <end_date>

Output:
    <output_dir>/bedrock_usage_report.zip containing:
      - charts/bedrock_token_summary.png
      - charts/bedrock_token_trend.png
      - charts/bedrock_agents_token_summary.png
      - charts/bedrock_agents_token_trend.png
      - Bedrock_Usage_Report.xlsx
"""

import pandas as pd
import json
import os
import sys
import zipfile
import subprocess
from datetime import datetime

import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt
import matplotlib.dates as mdates


# =============================================================================
# AWS Account Info
# =============================================================================

def get_aws_account_info():
    """Retrieve Account ID and Account Name (alias) from AWS CLI."""
    account_id = "UnknownAccountID"
    account_name = ""

    try:
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            account_id = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    try:
        result = subprocess.run(
            ["aws", "iam", "list-account-aliases", "--query", "AccountAliases[0]", "--output", "text"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip() and result.stdout.strip() != "None":
            account_name = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass

    return account_id, account_name


# =============================================================================
# Chart Generation
# =============================================================================

def generate_summary_bar_chart(df, title, output_path, id_column="Model ID"):
    """Generate a horizontal bar chart showing total input/output tokens per model."""
    if df.empty:
        return False

    fig, ax = plt.subplots(figsize=(12, max(6, len(df) * 0.8)))

    # Shorten model IDs for display
    labels = df[id_column].apply(lambda x: x.split('/')[-1] if '/' in str(x) else str(x)[:40])

    y_pos = range(len(labels))
    bar_height = 0.35

    input_tokens = df['Total Input Tokens'].astype(float)
    output_tokens = df['Total Output Tokens'].astype(float)

    bars1 = ax.barh([y - bar_height/2 for y in y_pos], input_tokens, bar_height,
                    label='Input Tokens', color='#4472C4', alpha=0.85)
    bars2 = ax.barh([y + bar_height/2 for y in y_pos], output_tokens, bar_height,
                    label='Output Tokens', color='#ED7D31', alpha=0.85)

    ax.set_xlabel('Token Count', fontsize=11)
    ax.set_title(title, fontsize=13, fontweight='bold', pad=15)
    ax.set_yticks(y_pos)
    ax.set_yticklabels(labels, fontsize=9)
    ax.legend(loc='lower right', fontsize=10)
    ax.grid(axis='x', alpha=0.3)

    # Add value labels
    for bar in bars1:
        width = bar.get_width()
        if width > 0:
            ax.text(width, bar.get_y() + bar.get_height()/2,
                    f' {int(width):,}', va='center', fontsize=8, color='#333333')
    for bar in bars2:
        width = bar.get_width()
        if width > 0:
            ax.text(width, bar.get_y() + bar.get_height()/2,
                    f' {int(width):,}', va='center', fontsize=8, color='#333333')

    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    return True


def generate_trend_chart(timeseries_data, source_filter, title, output_path):
    """Generate a line chart showing token usage over time per model."""
    filtered = [ts for ts in timeseries_data if ts.get('source') == source_filter]

    if not filtered:
        return False

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(14, 10), sharex=True)

    colors = plt.cm.Set2(range(len(filtered)))

    for idx, entry in enumerate(filtered):
        model = entry['model'].split('/')[-1] if '/' in entry['model'] else entry['model'][:30]
        region = entry.get('region', '')
        label = f"{model} ({region})"

        # Input tokens
        if entry.get('input_tokens'):
            input_df = pd.DataFrame(entry['input_tokens'])
            if not input_df.empty and 'Timestamp' in input_df.columns:
                input_df['Timestamp'] = pd.to_datetime(input_df['Timestamp'])
                input_df = input_df.sort_values('Timestamp')
                ax1.plot(input_df['Timestamp'], input_df['Sum'],
                         marker='o', markersize=4, label=label, color=colors[idx], linewidth=1.5)

        # Output tokens
        if entry.get('output_tokens'):
            output_df = pd.DataFrame(entry['output_tokens'])
            if not output_df.empty and 'Timestamp' in output_df.columns:
                output_df['Timestamp'] = pd.to_datetime(output_df['Timestamp'])
                output_df = output_df.sort_values('Timestamp')
                ax2.plot(output_df['Timestamp'], output_df['Sum'],
                         marker='s', markersize=4, label=label, color=colors[idx], linewidth=1.5)

    ax1.set_title(f'{title} - Input Tokens Over Time', fontsize=12, fontweight='bold')
    ax1.set_ylabel('Input Tokens', fontsize=10)
    ax1.legend(loc='upper left', fontsize=8, framealpha=0.9)
    ax1.grid(alpha=0.3)
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m-%d'))

    ax2.set_title(f'{title} - Output Tokens Over Time', fontsize=12, fontweight='bold')
    ax2.set_xlabel('Date', fontsize=10)
    ax2.set_ylabel('Output Tokens', fontsize=10)
    ax2.legend(loc='upper left', fontsize=8, framealpha=0.9)
    ax2.grid(alpha=0.3)
    ax2.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m-%d'))

    plt.xticks(rotation=45, ha='right')
    plt.tight_layout()
    plt.savefig(output_path, dpi=150, bbox_inches='tight')
    plt.close()
    return True


# =============================================================================
# Excel Generation
# =============================================================================

def generate_excel_report(bedrock_df, agents_df, output_path, account_label, start_date, end_date):
    """Generate a formatted Excel workbook with summary and detail sheets."""

    with pd.ExcelWriter(output_path, engine='openpyxl') as writer:
        # --- Summary Sheet ---
        summary_data = []

        if not bedrock_df.empty:
            total_input_br = bedrock_df['Total Input Tokens'].astype(float).sum()
            total_output_br = bedrock_df['Total Output Tokens'].astype(float).sum()
            total_invocations_br = bedrock_df['Invocations'].astype(float).sum()
            summary_data.append({
                'Source': 'Bedrock Runtime',
                'Total Input Tokens': int(total_input_br),
                'Total Output Tokens': int(total_output_br),
                'Total Tokens': int(total_input_br + total_output_br),
                'Total Invocations': int(total_invocations_br),
                'Models Used': len(bedrock_df),
            })

        if not agents_df.empty:
            total_input_ag = agents_df['Total Input Tokens'].astype(float).sum()
            total_output_ag = agents_df['Total Output Tokens'].astype(float).sum()
            total_invocations_ag = agents_df['Model Invocations'].astype(float).sum()
            summary_data.append({
                'Source': 'Bedrock Agents',
                'Total Input Tokens': int(total_input_ag),
                'Total Output Tokens': int(total_output_ag),
                'Total Tokens': int(total_input_ag + total_output_ag),
                'Total Invocations': int(total_invocations_ag),
                'Models Used': len(agents_df),
            })

        if summary_data:
            summary_df = pd.DataFrame(summary_data)
            # Add totals row
            totals = {
                'Source': 'TOTAL',
                'Total Input Tokens': summary_df['Total Input Tokens'].sum(),
                'Total Output Tokens': summary_df['Total Output Tokens'].sum(),
                'Total Tokens': summary_df['Total Tokens'].sum(),
                'Total Invocations': summary_df['Total Invocations'].sum(),
                'Models Used': summary_df['Models Used'].sum(),
            }
            summary_df = pd.concat([summary_df, pd.DataFrame([totals])], ignore_index=True)
            summary_df.to_excel(writer, sheet_name='Summary', index=False, startrow=3)

            # Write header info
            ws = writer.sheets['Summary']
            ws.cell(row=1, column=1, value=f'AWS Account: {account_label}')
            ws.cell(row=2, column=1, value=f'Period: {start_date} to {end_date}')

        # --- Bedrock Runtime Detail Sheet ---
        if not bedrock_df.empty:
            bedrock_df.to_excel(writer, sheet_name='Bedrock Runtime', index=False, startrow=2)
            ws = writer.sheets['Bedrock Runtime']
            ws.cell(row=1, column=1, value=f'Bedrock Runtime Token Usage ({start_date} to {end_date})')

        # --- Bedrock Agents Detail Sheet ---
        if not agents_df.empty:
            agents_df.to_excel(writer, sheet_name='Bedrock Agents', index=False, startrow=2)
            ws = writer.sheets['Bedrock Agents']
            ws.cell(row=1, column=1, value=f'Bedrock Agents Token Usage ({start_date} to {end_date})')

    return True


# =============================================================================
# ZIP Packaging
# =============================================================================

def create_zip_package(output_dir, chart_files, excel_path, zip_path):
    """Package all charts and Excel into a single ZIP file."""
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        # Add charts
        for chart_file in chart_files:
            if os.path.isfile(chart_file):
                arcname = f"charts/{os.path.basename(chart_file)}"
                zf.write(chart_file, arcname)

        # Add Excel
        if os.path.isfile(excel_path):
            zf.write(excel_path, os.path.basename(excel_path))

    return True


# =============================================================================
# Main
# =============================================================================

def main():
    if len(sys.argv) < 7:
        print("Usage: python3 generate_usage_charts.py <output_dir> <bedrock_csv> <agents_csv> <timeseries_json> <start_date> <end_date>")
        sys.exit(1)

    output_dir = sys.argv[1]
    bedrock_csv = sys.argv[2]
    agents_csv = sys.argv[3]
    timeseries_json = sys.argv[4]
    start_date = sys.argv[5]
    end_date = sys.argv[6]

    print("📊 Generating Bedrock Usage Charts and Excel Report...")
    print(f"   Period: {start_date} to {end_date}")

    # Get AWS Account Info
    print("   Retrieving AWS account info...")
    account_id, account_name = get_aws_account_info()
    if account_name:
        account_label = f"{account_name} ({account_id})"
    else:
        account_label = account_id
    print(f"   Account: {account_label}")

    # Create charts directory
    charts_dir = os.path.join(output_dir, "charts")
    os.makedirs(charts_dir, exist_ok=True)

    # Load CSV data
    bedrock_df = pd.DataFrame()
    agents_df = pd.DataFrame()

    if os.path.isfile(bedrock_csv):
        try:
            bedrock_df = pd.read_csv(bedrock_csv)
            if bedrock_df.empty or bedrock_df.shape[0] == 0:
                bedrock_df = pd.DataFrame()
        except (pd.errors.EmptyDataError, Exception):
            bedrock_df = pd.DataFrame()

    if os.path.isfile(agents_csv):
        try:
            agents_df = pd.read_csv(agents_csv)
            if agents_df.empty or agents_df.shape[0] == 0:
                agents_df = pd.DataFrame()
        except (pd.errors.EmptyDataError, Exception):
            agents_df = pd.DataFrame()

    # Load time-series data
    timeseries_data = []
    if os.path.isfile(timeseries_json):
        try:
            with open(timeseries_json, 'r') as f:
                timeseries_data = json.load(f)
        except (json.JSONDecodeError, Exception):
            timeseries_data = []

    chart_files = []

    # --- Generate Charts ---
    # 1. Bedrock Runtime Summary Bar Chart
    if not bedrock_df.empty:
        chart_path = os.path.join(charts_dir, "bedrock_token_summary.png")
        if generate_summary_bar_chart(bedrock_df, "Bedrock Runtime - Token Usage by Model", chart_path):
            chart_files.append(chart_path)
            print(f"   ✅ Generated: bedrock_token_summary.png")

    # 2. Bedrock Agents Summary Bar Chart
    if not agents_df.empty:
        id_col = "Agent Alias ARN" if "Agent Alias ARN" in agents_df.columns else "Model ID"
        chart_path = os.path.join(charts_dir, "bedrock_agents_token_summary.png")
        if generate_summary_bar_chart(agents_df, "Bedrock Agents - Token Usage", chart_path, id_column=id_col):
            chart_files.append(chart_path)
            print(f"   ✅ Generated: bedrock_agents_token_summary.png")

    # 3. Bedrock Runtime Trend Chart
    if timeseries_data:
        chart_path = os.path.join(charts_dir, "bedrock_token_trend.png")
        if generate_trend_chart(timeseries_data, "bedrock", "Bedrock Runtime", chart_path):
            chart_files.append(chart_path)
            print(f"   ✅ Generated: bedrock_token_trend.png")

        # 4. Bedrock Agents Trend Chart
        chart_path = os.path.join(charts_dir, "bedrock_agents_token_trend.png")
        if generate_trend_chart(timeseries_data, "agent", "Bedrock Agents", chart_path):
            chart_files.append(chart_path)
            print(f"   ✅ Generated: bedrock_agents_token_trend.png")

    # --- Generate Excel ---
    excel_path = os.path.join(output_dir, "Bedrock_Usage_Report.xlsx")
    if not bedrock_df.empty or not agents_df.empty:
        generate_excel_report(bedrock_df, agents_df, excel_path, account_label, start_date, end_date)
        print(f"   ✅ Generated: Bedrock_Usage_Report.xlsx")
    else:
        print("   ⚠️  No data available for Excel report.")
        excel_path = ""

    # --- Create ZIP ---
    zip_path = os.path.join(output_dir, "bedrock_usage_report.zip")
    if chart_files or excel_path:
        create_zip_package(output_dir, chart_files, excel_path, zip_path)
        print(f"\n   📦 ZIP package created: {zip_path}")
        print(f"      Contains: {len(chart_files)} chart(s) + Excel report")
    else:
        print("\n   ⚠️  No data to package. ZIP not created.")

    print("\n✅ Done!")


if __name__ == "__main__":
    main()

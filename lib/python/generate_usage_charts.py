"""
generate_usage_charts.py
Main entry point for Bedrock observability report generation.
Orchestrates: load data → build Excel sheets → package ZIP.

Usage:
    python3 generate_usage_charts.py <metrics_json> <output_dir> <start_date> <end_date>

Output:
    <output_dir>/Bedrock_Observability_Report.xlsx
    <output_dir>/bedrock_usage_report.zip
"""

import json
import os
import sys
import zipfile

# Add the lib/python directory to path for local imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from openpyxl import Workbook
from bedrock_helpers import get_aws_account_info
from bedrock_excel_sheets import (
    build_sheet_token_usage,
    build_sheet_latency,
    build_sheet_volume,
    build_sheet_reliability
)


def main():
    if len(sys.argv) < 5:
        print("Usage: python3 generate_usage_charts.py <metrics_json> <output_dir> <start_date> <end_date>")
        sys.exit(1)

    metrics_json_path = sys.argv[1]
    output_dir = sys.argv[2]
    start_date = sys.argv[3]
    end_date = sys.argv[4]
    period_str = f"{start_date} to {end_date}"

    print("📊 Generating Bedrock Observability Excel Report...")
    print(f"   Period: {period_str}")

    # Load metrics data
    with open(metrics_json_path, 'r') as f:
        data = json.load(f)

    all_models = data.get('models', [])
    if not all_models:
        print("   ⚠️  No model data found. Skipping report generation.")
        return

    bedrock_models = [m for m in all_models if m.get('source') == 'bedrock']
    agent_models = [m for m in all_models if m.get('source') == 'agent']
    all_for_charts = bedrock_models + agent_models

    print(f"   Models: {len(bedrock_models)} Bedrock + {len(agent_models)} Agent(s)")

    # AWS Account
    print("   Retrieving AWS account info...")
    account_id, account_name = get_aws_account_info()
    account_label = f"{account_name} ({account_id})" if account_name else account_id
    print(f"   Account: {account_label}")

    # Build workbook
    wb = Workbook()
    wb.remove(wb.active)

    print("   Sheet 1: Token Usage...")
    build_sheet_token_usage(wb, all_for_charts, account_label, period_str)

    print("   Sheet 2: Latency & Performance...")
    build_sheet_latency(wb, all_for_charts, account_label, period_str)

    print("   Sheet 3: Volume & Distribution...")
    build_sheet_volume(wb, all_for_charts, account_label, period_str)

    print("   Sheet 4: Reliability & Errors...")
    build_sheet_reliability(wb, all_for_charts, account_label, period_str)

    # Save Excel
    excel_path = os.path.join(output_dir, "Bedrock_Observability_Report.xlsx")
    wb.save(excel_path)
    print(f"   ✅ Excel saved: {excel_path}")

    # Create ZIP
    zip_path = os.path.join(output_dir, "bedrock_usage_report.zip")
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        zf.write(excel_path, "Bedrock_Observability_Report.xlsx")
        zf.write(metrics_json_path, "raw_metrics/bedrock_all_metrics.json")
    print(f"   📦 ZIP created: {zip_path}")

    print("\n✅ Done!")


if __name__ == "__main__":
    main()

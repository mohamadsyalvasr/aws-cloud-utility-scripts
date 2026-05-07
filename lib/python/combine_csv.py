import pandas as pd
import glob
import os
import sys
import subprocess

# Ensure imports work regardless of working directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from excel_styles import get_formats, get_highlight_function


def get_aws_account_info():
    """
    Mengambil Account ID dan Account Name (alias) dari AWS CLI.
    Mengembalikan tuple (account_id, account_name).
    """
    account_id = "UnknownAccountID"
    account_name = ""

    # Ambil Account ID dari sts get-caller-identity
    try:
        result = subprocess.run(
            ["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip():
            account_id = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"Warning: Gagal mengambil Account ID. {e}")

    # Ambil Account Name (alias) dari iam list-account-aliases
    try:
        result = subprocess.run(
            ["aws", "iam", "list-account-aliases", "--query", "AccountAliases[0]", "--output", "text"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0 and result.stdout.strip() and result.stdout.strip() != "None":
            account_name = result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        print(f"Warning: Gagal mengambil Account Alias. {e}")

    return account_id, account_name


def combine_csv_to_excel_single_sheet():
    """
    Menggabungkan semua file CSV dalam direktori yang diberikan
    ke dalam SATU file Excel, di mana semua data berada dalam SATU sheet
    dengan pemisah 1 baris kosong antar data file.
    """
    # Pastikan direktori output diberikan sebagai argumen
    if len(sys.argv) < 2:
        print("Error: Harap berikan path direktori sebagai argumen.")
        print("Usage: python combine_csv.py <csv_directory> [--skip-aws-info]")
        sys.exit(1)

    csv_directory = sys.argv[1]
    skip_aws_info = "--skip-aws-info" in sys.argv

    # Ambil Account Info dari AWS
    if skip_aws_info:
        account_id = "NoAccount"
        account_name = ""
        print("Skipping AWS account info lookup (--skip-aws-info flag).")
    else:
        print("Mengambil informasi AWS Account...")
        account_id, account_name = get_aws_account_info()
        print(f"  Account ID   : {account_id}")
        print(f"  Account Name : {account_name if account_name else '(no alias)'}")

    # Tentukan label dan filename
    # Jika account_name kosong atau sama dengan account_id, gunakan account_id saja
    if not account_name or account_name == account_id:
        display_label = account_id
        safe_filename_part = account_id
    else:
        display_label = f"{account_name} ({account_id})"
        safe_filename_part = f"{account_name}_{account_id}"

    # Sanitize untuk filename
    safe_filename_part = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in safe_filename_part)

    output_filename = os.path.join(
        csv_directory,
        f"Combined_AWS_Reports_{safe_filename_part}.xlsx"
    )

    # Cari semua file CSV di direktori yang ditentukan
    all_csv_files = sorted(glob.glob(os.path.join(csv_directory, "*.csv")))

    if not all_csv_files:
        print(f"Warning: Tidak ada file CSV (*.csv) yang ditemukan di direktori: {csv_directory}")
        return

    print(f"\nMemulai penggabungan {len(all_csv_files)} file CSV ke dalam SATU sheet...")
    print(f"Output: {output_filename}\n")

    try:
        sheet_name = "Combined_Data"

        with pd.ExcelWriter(output_filename, engine='xlsxwriter') as writer:
            workbook = writer.book
            worksheet = workbook.add_worksheet(sheet_name)

            # Load semua format dari excel_styles.py
            fmt = get_formats(workbook)

            # Tulis informasi akun di baris paling atas
            startrow = 0
            worksheet.write(startrow, 0, f"AWS Account: {display_label}", fmt['account_info'])
            startrow += 2  # Beri jarak 1 baris kosong setelah info akun

            for csv_file in all_csv_files:
                file_basename = os.path.basename(csv_file)

                try:
                    df = pd.read_csv(csv_file, encoding='utf-8')
                except UnicodeDecodeError:
                    df = pd.read_csv(csv_file, encoding='latin-1')
                except pd.errors.EmptyDataError:
                    print(f"  ⏭️  Skipping empty CSV file: {file_basename}")
                    continue

                # Skip CSV yang hanya berisi header tanpa data
                if df.shape[0] == 0:
                    print(f"  ⏭️  Skipping '{file_basename}' (no data, header only)")
                    continue

                # Ambil highlight function dari excel_styles (jika ada rule untuk file ini)
                highlight_fn = get_highlight_function(file_basename)
                columns_list = df.columns.tolist()

                # --- Tulis Header Sumber Data ---
                worksheet.write(startrow, 0, f"DATA DARI FILE: {file_basename}", fmt['source_header'])
                data_start_row = startrow + 1

                # --- Tulis Header Tabel dengan kolom No. di depan ---
                worksheet.write(data_start_row, 0, "No.", fmt['no_header'])
                for col_num, value in enumerate(df.columns.values):
                    worksheet.write(data_start_row, col_num + 1, value, fmt['table_header'])

                # --- Tulis Data Tabel dengan nomor urut ---
                data_rows = df.fillna('').values.tolist()
                current_row = data_start_row + 1

                for row_idx, row_data in enumerate(data_rows, start=1):
                    # Cek apakah baris ini perlu di-highlight
                    is_highlighted = False
                    if highlight_fn:
                        is_highlighted = highlight_fn(row_data, columns_list)

                    # Pilih format berdasarkan highlight status
                    if is_highlighted:
                        row_no_fmt = fmt['no_not_running']
                        row_data_fmt = fmt['highlight_not_running']
                    else:
                        row_no_fmt = fmt['no']
                        row_data_fmt = fmt['data']

                    # Tulis No.
                    worksheet.write(current_row, 0, row_idx, row_no_fmt)
                    # Tulis data
                    for col_num, value in enumerate(row_data):
                        worksheet.write(current_row, col_num + 1, value, row_data_fmt)
                    current_row += 1

                # Baris berikutnya: skip 1 baris kosong sebagai pemisah (tanpa warna)
                startrow = current_row + 1

                print(f"  ✅ '{file_basename}' ditambahkan ({df.shape[0]} baris data)")

            # Set lebar kolom No.
            worksheet.set_column(0, 0, 5)

        print(f"\n✅ Selesai! File disimpan: {output_filename}")

    except Exception as e:
        print(f"Error: Gagal membuat file Excel. {e}")
        sys.exit(1)


def combine_csv_to_excel_multi_sheet():
    """
    Menggabungkan semua file CSV dalam direktori yang diberikan
    ke dalam SATU file Excel dengan MULTI SHEET — setiap CSV menjadi sheet terpisah.
    """
    if len(sys.argv) < 2:
        print("Error: Harap berikan path direktori sebagai argumen.")
        print("Usage: python combine_csv.py <csv_directory> [--skip-aws-info] [--multi-sheet]")
        sys.exit(1)

    csv_directory = sys.argv[1]
    skip_aws_info = "--skip-aws-info" in sys.argv

    # Ambil Account Info dari AWS
    if skip_aws_info:
        account_id = "NoAccount"
        account_name = ""
    else:
        print("Mengambil informasi AWS Account...")
        account_id, account_name = get_aws_account_info()
        print(f"  Account ID   : {account_id}")
        print(f"  Account Name : {account_name if account_name else '(no alias)'}")

    # Tentukan label dan filename
    if not account_name or account_name == account_id:
        display_label = account_id
        safe_filename_part = account_id
    else:
        display_label = f"{account_name} ({account_id})"
        safe_filename_part = f"{account_name}_{account_id}"

    safe_filename_part = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in safe_filename_part)

    output_filename = os.path.join(
        csv_directory,
        f"Combined_AWS_Reports_{safe_filename_part}.xlsx"
    )

    # Cari semua file CSV
    all_csv_files = sorted(glob.glob(os.path.join(csv_directory, "*.csv")))

    if not all_csv_files:
        print(f"Warning: Tidak ada file CSV (*.csv) yang ditemukan di direktori: {csv_directory}")
        return

    print(f"\nMemulai penggabungan {len(all_csv_files)} file CSV ke dalam MULTI SHEET...")
    print(f"Output: {output_filename}\n")

    try:
        with pd.ExcelWriter(output_filename, engine='xlsxwriter') as writer:
            workbook = writer.book
            fmt = get_formats(workbook)

            for csv_file in all_csv_files:
                file_basename = os.path.basename(csv_file)

                try:
                    df = pd.read_csv(csv_file, encoding='utf-8')
                except UnicodeDecodeError:
                    df = pd.read_csv(csv_file, encoding='latin-1')
                except pd.errors.EmptyDataError:
                    print(f"  ⏭️  Skipping empty CSV file: {file_basename}")
                    continue

                if df.shape[0] == 0:
                    print(f"  ⏭️  Skipping '{file_basename}' (no data, header only)")
                    continue

                # Generate sheet name from filename (max 31 chars for Excel)
                sheet_name = file_basename.replace('.csv', '').replace('aws_', '').replace('_report', '')
                sheet_name = sheet_name[:31]  # Excel sheet name limit

                # Avoid duplicate sheet names
                existing_sheets = [ws.name for ws in workbook.worksheets()]
                if sheet_name in existing_sheets:
                    sheet_name = sheet_name[:28] + "_2"

                worksheet = workbook.add_worksheet(sheet_name)

                # Get highlight function
                highlight_fn = get_highlight_function(file_basename)
                columns_list = df.columns.tolist()

                # Row 0: Account info
                worksheet.write(0, 0, f"AWS Account: {display_label}", fmt['account_info'])

                # Row 2: Column headers
                header_row = 2
                worksheet.write(header_row, 0, "No.", fmt['no_header'])
                for col_num, value in enumerate(df.columns.values):
                    worksheet.write(header_row, col_num + 1, value, fmt['table_header'])

                # Row 3+: Data
                data_rows = df.fillna('').values.tolist()
                current_row = header_row + 1

                # Track column widths
                col_widths = [5]
                for col_name in columns_list:
                    col_widths.append(max(len(str(col_name)), 8))

                for row_idx, row_data in enumerate(data_rows, start=1):
                    # Check highlight
                    is_highlighted = False
                    if highlight_fn:
                        is_highlighted = highlight_fn(row_data, columns_list)

                    if is_highlighted:
                        row_no_fmt = fmt['no_not_running']
                        row_data_fmt = fmt['highlight_not_running']
                    else:
                        row_no_fmt = fmt['no']
                        row_data_fmt = fmt['data']

                    worksheet.write(current_row, 0, row_idx, row_no_fmt)
                    for col_num, value in enumerate(row_data):
                        worksheet.write(current_row, col_num + 1, value, row_data_fmt)
                        val_len = len(str(value)) if value != '' else 0
                        if col_num + 1 < len(col_widths):
                            col_widths[col_num + 1] = max(col_widths[col_num + 1], val_len)
                        else:
                            col_widths.append(max(val_len, 8))
                    current_row += 1

                # Auto-fit columns (cap at 40)
                for col_idx, width in enumerate(col_widths):
                    worksheet.set_column(col_idx, col_idx, min(width + 2, 40))

                print(f"  ✅ Sheet '{sheet_name}' ({df.shape[0]} baris dari {file_basename})")

        print(f"\n✅ Selesai! File disimpan: {output_filename}")

    except Exception as e:
        print(f"Error: Gagal membuat file Excel. {e}")
        sys.exit(1)


def combine_csv_to_excel_mode_sheets():
    """
    Mode=all: Generates 1 Excel file with sheets grouped by report type:
    - "Inventory" sheet: all inventory CSVs combined
    - "Optimization" sheet: all opt_* CSVs combined
    - "Security" sheet: all sec_* CSVs combined
    """
    if len(sys.argv) < 2:
        print("Error: Harap berikan path direktori sebagai argumen.")
        sys.exit(1)

    csv_directory = sys.argv[1]
    skip_aws_info = "--skip-aws-info" in sys.argv

    # Ambil Account Info
    if skip_aws_info:
        account_id = "NoAccount"
        account_name = ""
    else:
        print("Mengambil informasi AWS Account...")
        account_id, account_name = get_aws_account_info()
        print(f"  Account ID   : {account_id}")
        print(f"  Account Name : {account_name if account_name else '(no alias)'}")

    if not account_name or account_name == account_id:
        display_label = account_id
        safe_filename_part = account_id
    else:
        display_label = f"{account_name} ({account_id})"
        safe_filename_part = f"{account_name}_{account_id}"

    safe_filename_part = "".join(c if c.isalnum() or c in ("-", "_") else "_" for c in safe_filename_part)
    output_filename = os.path.join(csv_directory, f"Combined_AWS_Reports_{safe_filename_part}.xlsx")

    # Categorize CSV files by type
    all_csv_files = sorted(glob.glob(os.path.join(csv_directory, "*.csv")))
    if not all_csv_files:
        print(f"Warning: Tidak ada file CSV ditemukan di: {csv_directory}")
        return

    inventory_csvs = []
    optimization_csvs = []
    security_csvs = []

    for csv_file in all_csv_files:
        basename = os.path.basename(csv_file)
        if basename.startswith("opt_") or basename in ("ec2_rightsizing_report.csv", "rds_rightsizing_report.csv",
            "idle_resources_report.csv", "ebs_optimization_report.csv", "ri_sp_advisor_report.csv",
            "data_transfer_optimization_report.csv", "s3_storage_optimization_report.csv",
            "efs_storage_optimization_report.csv", "optimization_summary_report.csv",
            "trusted_advisor_report.csv", "cost_trend_report.csv"):
            optimization_csvs.append(csv_file)
        elif basename.startswith("sec_"):
            security_csvs.append(csv_file)
        else:
            inventory_csvs.append(csv_file)

    print(f"\nGrouping: {len(inventory_csvs)} inventory, {len(optimization_csvs)} optimization, {len(security_csvs)} security")
    print(f"Output: {output_filename}\n")

    try:
        with pd.ExcelWriter(output_filename, engine='xlsxwriter') as writer:
            workbook = writer.book
            fmt = get_formats(workbook)

            # Helper to write a group of CSVs into one sheet
            def write_mode_sheet(sheet_name, csv_files):
                if not csv_files:
                    return
                worksheet = workbook.add_worksheet(sheet_name)
                worksheet.write(0, 0, f"AWS Account: {display_label}", fmt['account_info'])
                startrow = 2

                for csv_file in csv_files:
                    file_basename = os.path.basename(csv_file)
                    try:
                        df = pd.read_csv(csv_file, encoding='utf-8')
                    except UnicodeDecodeError:
                        df = pd.read_csv(csv_file, encoding='latin-1')
                    except pd.errors.EmptyDataError:
                        continue

                    if df.shape[0] == 0:
                        continue

                    highlight_fn = get_highlight_function(file_basename)
                    columns_list = df.columns.tolist()

                    # Source header
                    worksheet.write(startrow, 0, f"DATA: {file_basename}", fmt['source_header'])
                    data_start_row = startrow + 1

                    # Column headers
                    worksheet.write(data_start_row, 0, "No.", fmt['no_header'])
                    for col_num, value in enumerate(df.columns.values):
                        worksheet.write(data_start_row, col_num + 1, value, fmt['table_header'])

                    # Data rows
                    data_rows = df.fillna('').values.tolist()
                    current_row = data_start_row + 1

                    for row_idx, row_data in enumerate(data_rows, start=1):
                        is_highlighted = False
                        if highlight_fn:
                            is_highlighted = highlight_fn(row_data, columns_list)

                        if is_highlighted:
                            row_no_fmt = fmt['no_not_running']
                            row_data_fmt = fmt['highlight_not_running']
                        else:
                            row_no_fmt = fmt['no']
                            row_data_fmt = fmt['data']

                        worksheet.write(current_row, 0, row_idx, row_no_fmt)
                        for col_num, value in enumerate(row_data):
                            worksheet.write(current_row, col_num + 1, value, row_data_fmt)
                        current_row += 1

                    startrow = current_row + 1

                worksheet.set_column(0, 0, 5)
                print(f"  ✅ Sheet '{sheet_name}' ({len(csv_files)} reports)")

            # Write each mode as a sheet
            write_mode_sheet("Inventory", inventory_csvs)
            write_mode_sheet("Optimization", optimization_csvs)
            write_mode_sheet("Security", security_csvs)

        print(f"\n✅ Selesai! File disimpan: {output_filename}")

    except Exception as e:
        print(f"Error: Gagal membuat file Excel. {e}")
        sys.exit(1)


if __name__ == "__main__":
    if "--multi-sheet" in sys.argv:
        combine_csv_to_excel_multi_sheet()
    elif "--mode-sheets" in sys.argv:
        combine_csv_to_excel_mode_sheets()
    else:
        combine_csv_to_excel_single_sheet()

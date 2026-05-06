import pandas as pd
import glob
import os
import sys
import subprocess

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


if __name__ == "__main__":
    combine_csv_to_excel_single_sheet()

import pandas as pd
import glob
import os
import sys

def combine_csv_to_excel_single_sheet():
    """
    Menggabungkan semua file CSV dalam direktori yang diberikan
    ke dalam SATU file Excel, di mana semua data berada dalam SATU sheet
    dengan pemisah 1 baris antar data file.
    """
    # Pastikan direktori output diberikan sebagai argumen
    if len(sys.argv) < 2:
        print("Error: Harap berikan path direktori sebagai argumen.")
        sys.exit(1)
        
    csv_directory = sys.argv[1]
    output_filename = os.path.join(csv_directory, "Combined_AWS_Reports.xlsx")
    
    # Cari semua file CSV di direktori yang ditentukan
    all_csv_files = glob.glob(os.path.join(csv_directory, "*.csv"))

    if not all_csv_files:
        print(f"Warning: Tidak ada file CSV (*.csv) yang ditemukan di direktori: {csv_directory}")
        return

    print(f"Memulai penggabungan {len(all_csv_files)} file CSV ke dalam SATU sheet...")
    
    try:
        sheet_name = "Combined_Data"
        
        # Gunakan Pandas ExcelWriter untuk mengelola penulisan
        with pd.ExcelWriter(output_filename, engine='xlsxwriter') as writer:
            workbook = writer.book
            worksheet = workbook.add_worksheet(sheet_name)
            
            # Format untuk header data dan baris pemisah
            source_header_format = workbook.add_format({'bold': True, 'bg_color': '#DDEBF7', 'border': 1}) # Warna Biru Muda
            separator_format = workbook.add_format({'fg_color': '#FFEB9C', 'border': 1}) # Warna Kuning Muda
            
            # Format untuk header tabel dan data
            table_header_format = workbook.add_format({'bold': True, 'border': 1, 'bg_color': '#F2F2F2'})
            data_format = workbook.add_format({'border': 1})

            startrow = 0
            
            for csv_file in all_csv_files:
                file_basename = os.path.basename(csv_file)
                
                try:
                    # Baca file CSV
                    df = pd.read_csv(csv_file, encoding='utf-8')
                except UnicodeDecodeError:
                    # Coba encoding lain jika utf-8 gagal
                    df = pd.read_csv(csv_file, encoding='latin-1')
                except pd.errors.EmptyDataError:
                    print(f"Skipping empty CSV file: {csv_file}")
                    continue
                
                # --- Tulis Baris Pemisah/Header Sumber Data ---
                
                # 1. Tambahkan baris untuk menandai awal data file ini
                worksheet.write(startrow, 0, f"DATA DARI FILE: {file_basename}", source_header_format)
                
                # Baris penulisan data DataFrame dimulai 1 baris di bawah baris pemisah/label
                data_start_row = startrow + 1
                
                # 2. Tulis Header Tabel Manually
                for col_num, value in enumerate(df.columns.values):
                     worksheet.write(data_start_row, col_num, value, table_header_format)

                # 3. Tulis Data Tabel Manually
                # Mengonversi df ke list of lists/records untuk iterasi
                # fillna('') untuk menghindari NaN di Excel
                data_rows = df.fillna('').values.tolist()
                
                current_row = data_start_row + 1
                for row_data in data_rows:
                    for col_num, value in enumerate(row_data):
                        worksheet.write(current_row, col_num, value, data_format)
                    current_row += 1
                
                # Hitung baris berikutnya:
                # data_start_row (baris awal data) 
                # + baris header DataFrame (1) 
                # + baris data (df.shape[0])
                next_startrow = data_start_row + 1 + df.shape[0]

                # 3. Tulis Baris Pemisah 1 Baris Kosong (sesuai permintaan)
                # Secara teknis, kita hanya perlu mengupdate 'startrow' untuk melewatkan 1 baris
                # Namun, untuk memperjelas batas visual, kita bisa menuliskan baris pemisah yang nyata.
                worksheet.write(next_startrow, 0, "PEMISAH 1 ROW", separator_format)
                
                # Perbarui startrow untuk iterasi berikutnya: 
                # Baris pemisah (next_startrow) + 1 baris kosong berikutnya
                startrow = next_startrow + 1
                
                print(f"Data dari '{file_basename}' berhasil ditambahkan. Next start row: {startrow}")
        
        print(f"Semua file CSV telah selesai digabungkan ke SATU sheet di '{output_filename}'.")

    except Exception as e:
        print(f"Error: Gagal membuat file Excel. {e}")
        sys.exit(1)

if __name__ == "__main__":
    combine_csv_to_excel_single_sheet()
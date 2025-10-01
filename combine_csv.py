import pandas as pd
import glob
import os
import sys

def combine_csv_to_excel():
    """
    Menggabungkan semua file CSV dalam direktori yang diberikan
    ke dalam satu file Excel, di mana setiap file CSV menjadi sheet terpisah.
    
    Skrip ini mengambil path direktori dari argumen baris perintah.
    """
    if len(sys.argv) < 2:
        print("Error: Harap berikan path direktori sebagai argumen.")
        sys.exit(1)
        
    # Ambil path direktori dari argumen pertama
    csv_directory = sys.argv[1]
    
    # Tentukan nama file output Excel
    output_filename = os.path.join(csv_directory, "Combined_AWS_Reports.xlsx")
    
    # Cari semua file CSV di direktori yang ditentukan
    # Kami hanya mencari file di direktori root output, bukan sub-sub direktori (non-recursive)
    all_csv_files = glob.glob(os.path.join(csv_directory, "*.csv"))

    if not all_csv_files:
        print(f"Warning: Tidak ada file CSV (*.csv) yang ditemukan di direktori: {csv_directory}")
        return

    # Inisialisasi ExcelWriter
    print(f"Memulai penggabungan {len(all_csv_files)} file CSV...")
    
    try:
        with pd.ExcelWriter(output_filename, engine='xlsxwriter') as writer:
            for csv_file in all_csv_files:
                # Ambil nama file (tanpa path dan ekstensi) untuk dijadikan nama sheet
                sheet_name = os.path.splitext(os.path.basename(csv_file))[0]
                
                # Batas nama sheet Excel adalah 31 karakter. Kita potong jika terlalu panjang.
                sheet_name = sheet_name[:31]
                
                try:
                    # Coba baca file CSV. Menggunakan encoding yang berbeda jika utf-8 gagal.
                    df = pd.read_csv(csv_file, encoding='utf-8')
                except UnicodeDecodeError:
                    df = pd.read_csv(csv_file, encoding='latin-1')
                except pd.errors.EmptyDataError:
                    print(f"Skipping empty CSV file: {csv_file}")
                    continue

                # Tulis DataFrame ke sheet yang sesuai (1 sheet per file CSV)
                # index=False mencegah penulisan indeks DataFrame
                df.to_excel(writer, sheet_name=sheet_name, index=False)
                
                # print(f"File '{os.path.basename(csv_file)}' ditulis ke sheet '{sheet_name}'") # Dihilangkan agar output shell lebih rapi

        print(f"Sukses: Semua file CSV digabungkan ke '{output_filename}'.")

    except Exception as e:
        print(f"Error: Gagal membuat file Excel. {e}")
        sys.exit(1)

if __name__ == "__main__":
    combine_csv_to_excel()
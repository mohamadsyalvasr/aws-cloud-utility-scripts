"""
excel_styles.py
Modul terpisah untuk aturan formatting/conditional styling pada Excel output.
Mudah di-maintain: tambahkan fungsi baru untuk setiap report yang butuh custom styling.
"""


def get_formats(workbook):
    """
    Mengembalikan dictionary berisi semua format yang digunakan di Excel.
    """
    formats = {
        # Header info akun
        'account_info': workbook.add_format({
            'bold': True, 'font_size': 12,
            'bg_color': '#4472C4', 'font_color': '#FFFFFF', 'border': 1
        }),
        # Header sumber data (nama file)
        'source_header': workbook.add_format({
            'bold': True, 'bg_color': '#DDEBF7', 'border': 1
        }),
        # Header tabel
        'table_header': workbook.add_format({
            'bold': True, 'border': 1, 'bg_color': '#F2F2F2'
        }),
        # Data biasa
        'data': workbook.add_format({'border': 1}),
        # Kolom No. header
        'no_header': workbook.add_format({
            'bold': True, 'border': 1, 'bg_color': '#F2F2F2', 'align': 'center'
        }),
        # Kolom No. data
        'no': workbook.add_format({'border': 1, 'align': 'center'}),
        # Highlight: instance/resource NOT running (merah muda)
        'highlight_not_running': workbook.add_format({
            'border': 1, 'bg_color': '#DEBABA'
        }),
        # Highlight: No. cell untuk row yang not running
        'no_not_running': workbook.add_format({
            'border': 1, 'align': 'center', 'bg_color': '#DEBABA'
        }),
    }
    return formats


# =============================================================================
# RULES PER REPORT
# =============================================================================
# Setiap fungsi menerima:
#   - row_data: list of values dari satu baris CSV
#   - columns: list of column names
# Mengembalikan:
#   - True jika baris harus di-highlight, False jika tidak
# =============================================================================

def should_highlight_ec2(row_data, columns):
    """
    EC2 Report: highlight jika 'Instance state' bukan 'running'.
    """
    try:
        state_idx = columns.index("Instance state")
        state = str(row_data[state_idx]).strip().lower()
        return state != "running"
    except (ValueError, IndexError):
        return False


def should_highlight_rds(row_data, columns):
    """
    RDS Report: highlight jika 'Instance state' bukan 'available'.
    """
    try:
        state_idx = columns.index("Instance state")
        state = str(row_data[state_idx]).strip().lower()
        return state != "available"
    except (ValueError, IndexError):
        return False


def should_highlight_ebs(row_data, columns):
    """
    EBS Report: highlight jika 'Volume state' bukan 'in-use'.
    """
    try:
        state_idx = columns.index("Volume state")
        state = str(row_data[state_idx]).strip().lower()
        return state != "in-use"
    except (ValueError, IndexError):
        return False


def should_highlight_iam(row_data, columns):
    """
    IAM Report: highlight jika Access Key aktif DAN MFA tidak enabled.
    Kondisi: (Key 1 Status == "Active" OR Key 2 Status == "Active") AND MFA Enabled == "No"
    """
    try:
        mfa_idx = columns.index("MFA Enabled")
        mfa_status = str(row_data[mfa_idx]).strip()

        key1_status_idx = columns.index("Key 1 Status")
        key1_status = str(row_data[key1_status_idx]).strip()

        key2_status_idx = columns.index("Key 2 Status")
        key2_status = str(row_data[key2_status_idx]).strip()

        has_active_key = (key1_status == "Active" or key2_status == "Active")
        no_mfa = (mfa_status == "No")

        return has_active_key and no_mfa
    except (ValueError, IndexError):
        return False


# =============================================================================
# MAPPING: filename pattern -> highlight function
# =============================================================================
# Key: substring yang ada di nama file CSV
# Value: fungsi yang menentukan apakah baris harus di-highlight
# =============================================================================

HIGHLIGHT_RULES = {
    "aws_ec2_report": should_highlight_ec2,
    "aws_rds_report": should_highlight_rds,
    "ebs_report": should_highlight_ebs,
    "iam_report": should_highlight_iam,
}


def get_highlight_function(filename):
    """
    Mengembalikan fungsi highlight yang sesuai berdasarkan nama file.
    Return None jika tidak ada rule untuk file tersebut.
    """
    for pattern, func in HIGHLIGHT_RULES.items():
        if pattern in filename:
            return func
    return None

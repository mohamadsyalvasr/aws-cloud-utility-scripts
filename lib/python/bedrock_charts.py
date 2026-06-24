"""
bedrock_charts.py
Chart generation functions for Bedrock observability report.
Each function returns a BytesIO PNG image or None if no data.
"""

from io import BytesIO
import pandas as pd
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

COLORS = ['#4472C4', '#ED7D31', '#A5A5A5', '#FFC000', '#5B9BD5',
           '#70AD47', '#264478', '#9B59B6', '#E74C3C', '#1ABC9C']


def chart_to_bytes(fig, dpi=130):
    """Convert matplotlib figure to PNG bytes."""
    buf = BytesIO()
    fig.savefig(buf, format='png', dpi=dpi, bbox_inches='tight')
    plt.close(fig)
    buf.seek(0)
    return buf


def _clean_spines(ax):
    for spine in ['top', 'right']:
        ax.spines[spine].set_visible(False)


# --- Import helpers from the shared module ---
from bedrock_helpers import datapoints_to_df, safe_sum, short_model_name


# =============================================================================
# TOKEN USAGE CHARTS
# =============================================================================
def make_token_usage_chart(models_data):
    """Bar chart: Input vs Output tokens per model with value labels."""
    labels = [short_model_name(m['model_id']) for m in models_data]
    input_vals = [safe_sum(m['metrics'].get('input_tokens', [])) for m in models_data]
    output_vals = [safe_sum(m['metrics'].get('output_tokens', [])) for m in models_data]

    fig, ax = plt.subplots(figsize=(14, max(5, len(labels) * 0.8)))
    y = range(len(labels))
    h = 0.35
    bars1 = ax.barh([i - h/2 for i in y], input_vals, h, label='Input Tokens', color=COLORS[0])
    bars2 = ax.barh([i + h/2 for i in y], output_vals, h, label='Output Tokens', color=COLORS[1])
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8)
    ax.set_xlabel('Token Count')
    ax.set_title('Input and Output Token Usage by Model', fontweight='bold')
    ax.legend(loc='lower right')
    ax.grid(axis='x', alpha=0.3)
    _clean_spines(ax)
    # Add value labels
    for bar in bars1:
        w = bar.get_width()
        if w > 0:
            ax.text(w, bar.get_y() + bar.get_height()/2, f' {int(w):,}',
                    va='center', fontsize=7, color='#333')
    for bar in bars2:
        w = bar.get_width()
        if w > 0:
            ax.text(w, bar.get_y() + bar.get_height()/2, f' {int(w):,}',
                    va='center', fontsize=7, color='#333')
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_token_trend_chart(models_data):
    """Line chart: Total tokens over time per model with endpoint values."""
    fig, ax = plt.subplots(figsize=(14, 6))
    for idx, m in enumerate(models_data):
        label = short_model_name(m['model_id'])
        input_dp = m['metrics'].get('input_tokens', [])
        output_dp = m['metrics'].get('output_tokens', [])
        if not input_dp:
            continue
        df_in = datapoints_to_df(input_dp)
        df_out = datapoints_to_df(output_dp)
        if df_in.empty:
            continue
        df_in = df_in.rename(columns={'Sum': 'InputSum'})
        if not df_out.empty:
            df_out = df_out.rename(columns={'Sum': 'OutputSum'})
            merged = pd.merge(df_in[['Timestamp', 'InputSum']], df_out[['Timestamp', 'OutputSum']],
                              on='Timestamp', how='outer').fillna(0)
            merged['Total'] = merged['InputSum'] + merged['OutputSum']
        else:
            merged = df_in[['Timestamp', 'InputSum']].copy()
            merged['Total'] = merged['InputSum']
        merged = merged.sort_values('Timestamp')
        color = COLORS[idx % len(COLORS)]
        ax.plot(merged['Timestamp'], merged['Total'], marker='o', markersize=3,
                label=label, color=color, linewidth=1.5)
        # Annotate last point with value
        if not merged.empty:
            last = merged.iloc[-1]
            ax.annotate(f'{int(last["Total"]):,}', xy=(last['Timestamp'], last['Total']),
                        fontsize=7, color=color, ha='left', va='bottom')
    ax.set_title('Total Tokens Over Time', fontweight='bold')
    ax.set_xlabel('Date')
    ax.set_ylabel('Total Tokens')
    ax.legend(loc='upper left', fontsize=7)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    _clean_spines(ax)
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_cache_chart(models_data):
    """Bar chart: Cache Read vs Write tokens with value labels."""
    labels, reads, writes = [], [], []
    for m in models_data:
        r = safe_sum(m['metrics'].get('cache_read_tokens', []))
        w = safe_sum(m['metrics'].get('cache_write_tokens', []))
        if r > 0 or w > 0:
            labels.append(short_model_name(m['model_id']))
            reads.append(r)
            writes.append(w)
    if not labels:
        return None
    fig, ax = plt.subplots(figsize=(12, max(4, len(labels) * 0.7)))
    y = range(len(labels))
    h = 0.35
    bars1 = ax.barh([i - h/2 for i in y], reads, h, label='Cache Read', color=COLORS[4])
    bars2 = ax.barh([i + h/2 for i in y], writes, h, label='Cache Write', color=COLORS[5])
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8)
    ax.set_xlabel('Token Count')
    ax.set_title('Prompt Cache Usage (Read vs Write Tokens)', fontweight='bold')
    ax.legend()
    ax.grid(axis='x', alpha=0.3)
    for bar in bars1:
        w = bar.get_width()
        if w > 0:
            ax.text(w, bar.get_y() + bar.get_height()/2, f' {int(w):,}', va='center', fontsize=7)
    for bar in bars2:
        w = bar.get_width()
        if w > 0:
            ax.text(w, bar.get_y() + bar.get_height()/2, f' {int(w):,}', va='center', fontsize=7)
    plt.tight_layout()
    return chart_to_bytes(fig)


# =============================================================================
# LATENCY & PERFORMANCE CHARTS
# =============================================================================
def make_latency_chart(models_data):
    """Line chart: Average InvocationLatency over time with endpoint values."""
    fig, ax = plt.subplots(figsize=(14, 6))
    for idx, m in enumerate(models_data):
        dp = m['metrics'].get('invocation_latency', m['metrics'].get('model_latency', []))
        if not dp:
            continue
        df = datapoints_to_df(dp, 'Average')
        if df.empty or 'Average' not in df.columns:
            continue
        label = short_model_name(m['model_id'])
        color = COLORS[idx % len(COLORS)]
        ax.plot(df['Timestamp'], df['Average'], marker='o', markersize=3,
                label=label, color=color, linewidth=1.5)
        # Annotate last point
        if not df.empty:
            last = df.iloc[-1]
            ax.annotate(f'{last["Average"]:,.0f}ms', xy=(last['Timestamp'], last['Average']),
                        fontsize=7, color=color, ha='left', va='bottom')
    ax.set_title('End-to-End Invocation Latency (Avg ms)', fontweight='bold')
    ax.set_xlabel('Date')
    ax.set_ylabel('Latency (ms)')
    ax.legend(loc='upper left', fontsize=7)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_ttft_chart(models_data):
    """Line chart: Time To First Token over time."""
    fig, ax = plt.subplots(figsize=(12, 5))
    has_data = False
    for idx, m in enumerate(models_data):
        dp = m['metrics'].get('time_to_first_token', [])
        if not dp:
            continue
        df = datapoints_to_df(dp, 'Average')
        if df.empty or 'Average' not in df.columns:
            continue
        has_data = True
        label = short_model_name(m['model_id'])
        ax.plot(df['Timestamp'], df['Average'], marker='s', markersize=3,
                label=label, color=COLORS[idx % len(COLORS)], linewidth=1.5)
    if not has_data:
        plt.close(fig)
        return None
    ax.set_title('Time To First Token - TTFT (Avg ms)', fontweight='bold')
    ax.set_xlabel('Date')
    ax.set_ylabel('TTFT (ms)')
    ax.legend(loc='upper left', fontsize=8)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_tpm_chart(models_data):
    """Line chart: Estimated TPM Quota Usage over time."""
    fig, ax = plt.subplots(figsize=(12, 5))
    has_data = False
    for idx, m in enumerate(models_data):
        dp = m['metrics'].get('estimated_tpm_quota', [])
        if not dp:
            continue
        df = datapoints_to_df(dp, 'Maximum')
        if df.empty or 'Maximum' not in df.columns:
            continue
        has_data = True
        label = short_model_name(m['model_id'])
        ax.plot(df['Timestamp'], df['Maximum'], marker='^', markersize=3,
                label=label, color=COLORS[idx % len(COLORS)], linewidth=1.5)
    if not has_data:
        plt.close(fig)
        return None
    ax.set_title('Estimated TPM Quota Usage (Max)', fontweight='bold')
    ax.set_xlabel('Date')
    ax.set_ylabel('Tokens Per Minute')
    ax.legend(loc='upper left', fontsize=8)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    plt.tight_layout()
    return chart_to_bytes(fig)


# =============================================================================
# VOLUME & DISTRIBUTION CHARTS
# =============================================================================
def make_invocation_count_chart(models_data):
    """Line chart: Invocation count over time with endpoint values."""
    fig, ax = plt.subplots(figsize=(14, 6))
    for idx, m in enumerate(models_data):
        dp = m['metrics'].get('invocations', m['metrics'].get('model_invocations', []))
        if not dp:
            continue
        df = datapoints_to_df(dp)
        if df.empty or 'Sum' not in df.columns:
            continue
        label = short_model_name(m['model_id'])
        color = COLORS[idx % len(COLORS)]
        ax.plot(df['Timestamp'], df['Sum'], marker='o', markersize=3,
                label=label, color=color, linewidth=1.5)
        # Annotate last point
        if not df.empty:
            last = df.iloc[-1]
            ax.annotate(f'{int(last["Sum"]):,}', xy=(last['Timestamp'], last['Sum']),
                        fontsize=7, color=color, ha='left', va='bottom')
    ax.set_title('Invocation Count Over Time', fontweight='bold')
    ax.set_xlabel('Date')
    ax.set_ylabel('Invocations')
    ax.legend(loc='upper left', fontsize=7)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_token_distribution_chart(models_data):
    """Range chart: Input token size distribution per model (min|avg|max) with values."""
    fig, ax = plt.subplots(figsize=(14, max(5, len(models_data) * 0.8)))
    labels, avgs, mins, maxs = [], [], [], []
    for m in models_data:
        dp = m['metrics'].get('input_tokens', [])
        if not dp:
            continue
        avg_vals = [d.get('Average', 0) or 0 for d in dp if d.get('Average') is not None]
        min_vals = [d.get('Minimum', 0) or 0 for d in dp if d.get('Minimum') is not None]
        max_vals = [d.get('Maximum', 0) or 0 for d in dp if d.get('Maximum') is not None]
        if not avg_vals:
            continue
        labels.append(short_model_name(m['model_id']))
        avgs.append(sum(avg_vals) / len(avg_vals))
        mins.append(min(min_vals) if min_vals else 0)
        maxs.append(max(max_vals) if max_vals else 0)
    if not labels:
        plt.close(fig)
        return None
    y = range(len(labels))
    for i in range(len(labels)):
        ax.plot([mins[i], maxs[i]], [i, i], color=COLORS[2], linewidth=2, solid_capstyle='round')
        ax.plot(avgs[i], i, 'o', color=COLORS[0], markersize=8)
        # Value labels
        ax.text(maxs[i], i, f' max:{int(maxs[i]):,}', va='center', fontsize=7, color='#666')
        ax.text(avgs[i], i + 0.2, f'avg:{int(avgs[i]):,}', va='bottom', fontsize=7, color=COLORS[0], ha='center')
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8)
    ax.set_xlabel('Input Tokens per Request')
    ax.set_title('Request Distribution by Input Token Size (Min | Avg | Max)', fontweight='bold')
    ax.grid(axis='x', alpha=0.3)
    plt.tight_layout()
    return chart_to_bytes(fig)


# =============================================================================
# RELIABILITY & ERRORS CHARTS
# =============================================================================
def make_throttles_chart(models_data):
    """Line chart: Throttles over time."""
    fig, ax = plt.subplots(figsize=(12, 5))
    has_data = False
    for idx, m in enumerate(models_data):
        dp = m['metrics'].get('throttles', [])
        if not dp:
            continue
        df = datapoints_to_df(dp)
        if df.empty or 'Sum' not in df.columns or df['Sum'].sum() == 0:
            continue
        has_data = True
        label = short_model_name(m['model_id'])
        ax.plot(df['Timestamp'], df['Sum'], marker='x', markersize=4,
                label=label, color=COLORS[idx % len(COLORS)], linewidth=1.5)
    if not has_data:
        plt.close(fig)
        return None
    ax.set_title('Invocation Throttles Over Time', fontweight='bold')
    ax.set_xlabel('Date')
    ax.set_ylabel('Throttle Count')
    ax.legend(loc='upper left', fontsize=8)
    ax.grid(alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_errors_chart(models_data):
    """Stacked bar: Client vs Server errors per model with value labels."""
    labels, client_errs, server_errs = [], [], []
    for m in models_data:
        ce = safe_sum(m['metrics'].get('client_errors', []))
        se = safe_sum(m['metrics'].get('server_errors', []))
        if ce > 0 or se > 0:
            labels.append(short_model_name(m['model_id']))
            client_errs.append(ce)
            server_errs.append(se)
    if not labels:
        return None
    fig, ax = plt.subplots(figsize=(12, max(4, len(labels) * 0.7)))
    y = range(len(labels))
    bars1 = ax.barh(y, client_errs, label='Client Errors (4xx)', color=COLORS[1])
    bars2 = ax.barh(y, server_errs, left=client_errs, label='Server Errors (5xx)', color=COLORS[8])
    ax.set_yticks(y)
    ax.set_yticklabels(labels, fontsize=8)
    ax.set_xlabel('Error Count')
    ax.set_title('Invocation Errors (Client vs Server)', fontweight='bold')
    ax.legend()
    ax.grid(axis='x', alpha=0.3)
    for i, bar in enumerate(bars1):
        w = bar.get_width()
        if w > 0:
            ax.text(w/2, bar.get_y() + bar.get_height()/2, f'{int(w):,}',
                    va='center', ha='center', fontsize=7, color='white', fontweight='bold')
    for i, bar in enumerate(bars2):
        w = bar.get_width()
        if w > 0:
            ax.text(client_errs[i] + w/2, bar.get_y() + bar.get_height()/2, f'{int(w):,}',
                    va='center', ha='center', fontsize=7, color='white', fontweight='bold')
    plt.tight_layout()
    return chart_to_bytes(fig)


def make_errors_trend_chart(models_data):
    """Line chart: Client + Server errors over time."""
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), sharex=True)
    has_client, has_server = False, False
    for idx, m in enumerate(models_data):
        label = short_model_name(m['model_id'])
        color = COLORS[idx % len(COLORS)]
        dp = m['metrics'].get('client_errors', [])
        if dp:
            df = datapoints_to_df(dp)
            if not df.empty and 'Sum' in df.columns and df['Sum'].sum() > 0:
                has_client = True
                ax1.plot(df['Timestamp'], df['Sum'], marker='x', markersize=3,
                         label=label, color=color, linewidth=1.5)
        dp = m['metrics'].get('server_errors', [])
        if dp:
            df = datapoints_to_df(dp)
            if not df.empty and 'Sum' in df.columns and df['Sum'].sum() > 0:
                has_server = True
                ax2.plot(df['Timestamp'], df['Sum'], marker='x', markersize=3,
                         label=label, color=color, linewidth=1.5)
    if not has_client and not has_server:
        plt.close(fig)
        return None
    ax1.set_title('Client Errors (4xx) Over Time', fontweight='bold')
    ax1.set_ylabel('Count')
    ax1.legend(fontsize=8)
    ax1.grid(alpha=0.3)
    ax2.set_title('Server Errors (5xx) Over Time', fontweight='bold')
    ax2.set_xlabel('Date')
    ax2.set_ylabel('Count')
    ax2.legend(fontsize=8)
    ax2.grid(alpha=0.3)
    ax2.xaxis.set_major_formatter(mdates.DateFormatter('%m-%d'))
    plt.xticks(rotation=45)
    plt.tight_layout()
    return chart_to_bytes(fig)

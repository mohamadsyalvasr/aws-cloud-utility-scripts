"""
bedrock_excel_sheets.py
Excel sheet builders for Bedrock observability report.
Each function builds one sheet with table, charts, and conclusion.
"""

from bedrock_helpers import (
    TITLE_FONT, SUBTITLE_FONT,
    safe_sum, safe_avg, short_model_name,
    write_section_header, write_table, insert_chart_image, write_conclusion
)
from bedrock_charts import (
    make_token_usage_chart, make_token_trend_chart, make_cache_chart,
    make_latency_chart, make_ttft_chart, make_tpm_chart,
    make_invocation_count_chart, make_token_distribution_chart,
    make_throttles_chart, make_errors_chart, make_errors_trend_chart
)


# =============================================================================
# Conclusion Generators (rule-based, no AI)
# =============================================================================
def _conclude_token_usage(models_data):
    """Generate conclusions for token usage sheet."""
    conclusions = []
    total_in = sum(safe_sum(m['metrics'].get('input_tokens', [])) for m in models_data)
    total_out = sum(safe_sum(m['metrics'].get('output_tokens', [])) for m in models_data)
    total_all = total_in + total_out

    if total_all == 0:
        return ["No token usage detected in this period."]

    # Top consumer
    usage_per_model = [(short_model_name(m['model_id']),
                        safe_sum(m['metrics'].get('input_tokens', [])) +
                        safe_sum(m['metrics'].get('output_tokens', [])))
                       for m in models_data]
    usage_per_model.sort(key=lambda x: x[1], reverse=True)
    top = usage_per_model[0]
    top_pct = (top[1] / total_all * 100) if total_all > 0 else 0
    conclusions.append(f"Total tokens consumed: {total_all:,.0f} (Input: {total_in:,.0f}, Output: {total_out:,.0f})")
    conclusions.append(f"Highest consumer: {top[0]} ({top_pct:.1f}% of total usage)")

    # Input vs Output ratio
    ratio = total_out / total_in if total_in > 0 else 0
    if ratio > 3:
        conclusions.append(f"Output/Input ratio is high ({ratio:.1f}x) — models generating long responses.")
    elif ratio < 0.3:
        conclusions.append(f"Output/Input ratio is low ({ratio:.2f}x) — large prompts with short responses.")

    # Cache usage
    total_cache_read = sum(safe_sum(m['metrics'].get('cache_read_tokens', [])) for m in models_data)
    if total_cache_read > 0:
        cache_pct = total_cache_read / total_in * 100 if total_in > 0 else 0
        conclusions.append(f"Prompt cache hit rate: {cache_pct:.1f}% of input tokens served from cache.")
    else:
        conclusions.append("No prompt caching detected. Consider enabling prompt cache for repeated prompts.")

    return conclusions


def _conclude_latency(models_data):
    """Generate conclusions for latency sheet."""
    conclusions = []
    latencies = []
    for m in models_data:
        dp = m['metrics'].get('invocation_latency', m['metrics'].get('model_latency', []))
        avg = safe_avg(dp, 'Average')
        if avg > 0:
            latencies.append((short_model_name(m['model_id']), avg))

    if not latencies:
        return ["No latency data available for this period."]

    latencies.sort(key=lambda x: x[1], reverse=True)
    slowest = latencies[0]
    fastest = latencies[-1]

    conclusions.append(f"Slowest model: {slowest[0]} (avg {slowest[1]:,.0f} ms)")
    conclusions.append(f"Fastest model: {fastest[0]} (avg {fastest[1]:,.0f} ms)")

    if slowest[1] > 10000:
        conclusions.append(f"WARNING: {slowest[0]} exceeds 10s average latency. Consider using streaming or a smaller model.")
    elif slowest[1] > 5000:
        conclusions.append(f"NOTE: {slowest[0]} averages over 5s. Monitor for user experience impact.")

    # TTFT check
    ttft_models = []
    for m in models_data:
        dp = m['metrics'].get('time_to_first_token', [])
        avg = safe_avg(dp, 'Average')
        if avg > 0:
            ttft_models.append((short_model_name(m['model_id']), avg))
    if ttft_models:
        ttft_models.sort(key=lambda x: x[1], reverse=True)
        conclusions.append(f"Slowest TTFT: {ttft_models[0][0]} ({ttft_models[0][1]:,.0f} ms)")
    else:
        conclusions.append("No TTFT data — streaming APIs not used or not emitting this metric.")

    return conclusions


def _conclude_volume(models_data):
    """Generate conclusions for volume & distribution sheet."""
    conclusions = []
    total_inv = sum(safe_sum(m['metrics'].get('invocations', m['metrics'].get('model_invocations', [])))
                    for m in models_data)

    if total_inv == 0:
        return ["No invocations detected in this period."]

    conclusions.append(f"Total invocations across all models: {total_inv:,.0f}")

    # Top invoked model
    inv_per_model = [(short_model_name(m['model_id']),
                      safe_sum(m['metrics'].get('invocations', m['metrics'].get('model_invocations', []))))
                     for m in models_data]
    inv_per_model.sort(key=lambda x: x[1], reverse=True)
    top = inv_per_model[0]
    conclusions.append(f"Most invoked: {top[0]} ({top[1]:,.0f} invocations, {top[1]/total_inv*100:.1f}% of total)")

    # Token size distribution insight
    for m in models_data:
        dp = m['metrics'].get('input_tokens', [])
        if not dp:
            continue
        max_vals = [d.get('Maximum', 0) or 0 for d in dp if d.get('Maximum') is not None]
        if max_vals and max(max_vals) > 100000:
            conclusions.append(f"Large prompts detected: {short_model_name(m['model_id'])} has requests with {max(max_vals):,.0f}+ input tokens.")
            break

    # Average tokens per request
    total_tokens = sum(safe_sum(m['metrics'].get('input_tokens', [])) +
                       safe_sum(m['metrics'].get('output_tokens', []))
                       for m in models_data)
    if total_inv > 0:
        avg_per_req = total_tokens / total_inv
        conclusions.append(f"Average tokens per request: {avg_per_req:,.0f}")

    return conclusions


def _conclude_reliability(models_data):
    """Generate conclusions for reliability & errors sheet."""
    conclusions = []
    total_inv = sum(safe_sum(m['metrics'].get('invocations', m['metrics'].get('model_invocations', [])))
                    for m in models_data)
    total_throttles = sum(safe_sum(m['metrics'].get('throttles', [])) for m in models_data)
    total_client_err = sum(safe_sum(m['metrics'].get('client_errors', [])) for m in models_data)
    total_server_err = sum(safe_sum(m['metrics'].get('server_errors', [])) for m in models_data)
    total_errors = total_client_err + total_server_err
    total_attempts = total_inv + total_throttles + total_errors

    if total_attempts == 0:
        return ["No invocation attempts detected in this period."]

    # Success rate
    success_rate = (total_inv / total_attempts * 100) if total_attempts > 0 else 0
    conclusions.append(f"Overall success rate: {success_rate:.2f}% ({total_inv:,.0f} successful / {total_attempts:,.0f} total attempts)")

    # Throttle analysis
    if total_throttles > 0:
        throttle_rate = total_throttles / total_attempts * 100
        conclusions.append(f"Throttle rate: {throttle_rate:.2f}% ({total_throttles:,.0f} throttled). Consider requesting quota increase.")
    else:
        conclusions.append("No throttling detected. Quota usage is within limits.")

    # Error analysis
    if total_errors > 0:
        error_rate = total_errors / total_attempts * 100
        conclusions.append(f"Error rate: {error_rate:.2f}% (Client: {total_client_err:,.0f}, Server: {total_server_err:,.0f})")
        if total_client_err > total_server_err:
            conclusions.append("Client errors dominate — check request formatting, model availability, or input validation.")
        elif total_server_err > 0:
            conclusions.append("Server errors detected — these are AWS-side. Monitor for recurring patterns.")
    else:
        conclusions.append("No errors detected in this period. System is operating cleanly.")

    return conclusions


# =============================================================================
# Sheet Builders
# =============================================================================
def build_sheet_token_usage(wb, models_data, account_label, period_str):
    """Sheet 1: Token Usage — table + charts + conclusion."""
    ws = wb.create_sheet("Token Usage")
    ws.cell(row=1, column=1, value=f"Bedrock Token Usage - {account_label}").font = TITLE_FONT
    ws.cell(row=2, column=1, value=f"Period: {period_str}").font = SUBTITLE_FONT
    row = 4

    headers = ['Model', 'Region', 'Input Tokens', 'Output Tokens', 'Total Tokens',
               'Cache Read', 'Cache Write', 'Invocations']
    data = []
    for m in models_data:
        inp = safe_sum(m['metrics'].get('input_tokens', []))
        out = safe_sum(m['metrics'].get('output_tokens', []))
        cr = safe_sum(m['metrics'].get('cache_read_tokens', []))
        cw = safe_sum(m['metrics'].get('cache_write_tokens', []))
        inv = safe_sum(m['metrics'].get('invocations', m['metrics'].get('model_invocations', [])))
        data.append([short_model_name(m['model_id']), m['region'],
                     int(inp), int(out), int(inp + out), int(cr), int(cw), int(inv)])
    row = write_table(ws, row, headers, data)
    row += 2

    row = write_section_header(ws, row, "Input & Output Token Usage")
    row = insert_chart_image(ws, row, 1, make_token_usage_chart(models_data))
    row += 1
    row = write_section_header(ws, row, "Total Tokens Over Time")
    row = insert_chart_image(ws, row, 1, make_token_trend_chart(models_data))
    row += 1
    row = write_section_header(ws, row, "Prompt Cache Usage (Read vs Write)")
    cache_chart = make_cache_chart(models_data)
    if cache_chart:
        row = insert_chart_image(ws, row, 1, cache_chart)
    else:
        ws.cell(row=row, column=1, value="No prompt cache data available.").font = SUBTITLE_FONT
        row += 2

    # Conclusion
    row += 1
    write_conclusion(ws, row, _conclude_token_usage(models_data))
    return ws


def build_sheet_latency(wb, models_data, account_label, period_str):
    """Sheet 2: Latency & Performance — table + charts + conclusion."""
    ws = wb.create_sheet("Latency & Performance")
    ws.cell(row=1, column=1, value=f"Bedrock Latency & Performance - {account_label}").font = TITLE_FONT
    ws.cell(row=2, column=1, value=f"Period: {period_str}").font = SUBTITLE_FONT
    row = 4

    headers = ['Model', 'Region', 'Avg Latency (ms)', 'Min Latency', 'Max Latency',
               'Avg TTFT (ms)', 'Max TPM Quota']
    data = []
    for m in models_data:
        lat = m['metrics'].get('invocation_latency', m['metrics'].get('model_latency', []))
        ttft = m['metrics'].get('time_to_first_token', [])
        tpm = m['metrics'].get('estimated_tpm_quota', [])
        avg_lat = safe_avg(lat, 'Average')
        min_lat = min((d.get('Minimum', 0) or 0 for d in lat), default=0) if lat else 0
        max_lat = max((d.get('Maximum', 0) or 0 for d in lat), default=0) if lat else 0
        avg_ttft = safe_avg(ttft, 'Average')
        max_tpm = max((d.get('Maximum', 0) or 0 for d in tpm), default=0) if tpm else 0
        data.append([short_model_name(m['model_id']), m['region'],
                     round(avg_lat, 1), round(min_lat, 1), round(max_lat, 1),
                     round(avg_ttft, 1), int(max_tpm)])
    row = write_table(ws, row, headers, data)
    row += 2

    row = write_section_header(ws, row, "End-to-End Invocation Latency")
    row = insert_chart_image(ws, row, 1, make_latency_chart(models_data))
    row += 1
    row = write_section_header(ws, row, "Time To First Token (TTFT)")
    ttft_chart = make_ttft_chart(models_data)
    if ttft_chart:
        row = insert_chart_image(ws, row, 1, ttft_chart)
    else:
        ws.cell(row=row, column=1, value="No TTFT data (streaming APIs only).").font = SUBTITLE_FONT
        row += 2
    row += 1
    row = write_section_header(ws, row, "Estimated TPM Quota Usage")
    tpm_chart = make_tpm_chart(models_data)
    if tpm_chart:
        row = insert_chart_image(ws, row, 1, tpm_chart)
    else:
        ws.cell(row=row, column=1, value="No TPM quota data available.").font = SUBTITLE_FONT
        row += 2

    row += 1
    write_conclusion(ws, row, _conclude_latency(models_data))
    return ws


def build_sheet_volume(wb, models_data, account_label, period_str):
    """Sheet 3: Volume & Distribution — table + charts + conclusion."""
    ws = wb.create_sheet("Volume & Distribution")
    ws.cell(row=1, column=1, value=f"Bedrock Volume & Distribution - {account_label}").font = TITLE_FONT
    ws.cell(row=2, column=1, value=f"Period: {period_str}").font = SUBTITLE_FONT
    row = 4

    headers = ['Model', 'Region', 'Total Invocations', 'Avg Input Tokens/Req',
               'Min Input Tokens', 'Max Input Tokens']
    data = []
    for m in models_data:
        inv = safe_sum(m['metrics'].get('invocations', m['metrics'].get('model_invocations', [])))
        inp_dp = m['metrics'].get('input_tokens', [])
        avg_inp = safe_avg(inp_dp, 'Average')
        min_inp = min((d.get('Minimum', 0) or 0 for d in inp_dp), default=0) if inp_dp else 0
        max_inp = max((d.get('Maximum', 0) or 0 for d in inp_dp), default=0) if inp_dp else 0
        data.append([short_model_name(m['model_id']), m['region'],
                     int(inv), round(avg_inp, 0), int(min_inp), int(max_inp)])
    row = write_table(ws, row, headers, data)
    row += 2

    row = write_section_header(ws, row, "Invocation Count Over Time")
    row = insert_chart_image(ws, row, 1, make_invocation_count_chart(models_data))
    row += 1
    row = write_section_header(ws, row, "Request Distribution by Input Token Size")
    dist_chart = make_token_distribution_chart(models_data)
    if dist_chart:
        row = insert_chart_image(ws, row, 1, dist_chart)
    else:
        ws.cell(row=row, column=1, value="No distribution data available.").font = SUBTITLE_FONT
        row += 2

    row += 1
    write_conclusion(ws, row, _conclude_volume(models_data))
    return ws


def build_sheet_reliability(wb, models_data, account_label, period_str):
    """Sheet 4: Reliability & Errors — table + charts + conclusion."""
    ws = wb.create_sheet("Reliability & Errors")
    ws.cell(row=1, column=1, value=f"Bedrock Reliability & Errors - {account_label}").font = TITLE_FONT
    ws.cell(row=2, column=1, value=f"Period: {period_str}").font = SUBTITLE_FONT
    row = 4

    headers = ['Model', 'Region', 'Invocations', 'Throttles', 'Client Errors',
               'Server Errors', 'Error Rate %']
    data = []
    for m in models_data:
        inv = safe_sum(m['metrics'].get('invocations', m['metrics'].get('model_invocations', [])))
        thr = safe_sum(m['metrics'].get('throttles', []))
        ce = safe_sum(m['metrics'].get('client_errors', []))
        se = safe_sum(m['metrics'].get('server_errors', []))
        total_attempts = inv + thr + ce + se
        err_rate = ((ce + se) / total_attempts * 100) if total_attempts > 0 else 0
        data.append([short_model_name(m['model_id']), m['region'],
                     int(inv), int(thr), int(ce), int(se), round(err_rate, 2)])
    row = write_table(ws, row, headers, data)
    row += 2

    row = write_section_header(ws, row, "Invocation Throttles Over Time")
    throttle_chart = make_throttles_chart(models_data)
    if throttle_chart:
        row = insert_chart_image(ws, row, 1, throttle_chart)
    else:
        ws.cell(row=row, column=1, value="No throttles in this period.").font = SUBTITLE_FONT
        row += 2
    row += 1
    row = write_section_header(ws, row, "Invocation Errors (Client vs Server)")
    err_chart = make_errors_chart(models_data)
    if err_chart:
        row = insert_chart_image(ws, row, 1, err_chart)
    else:
        ws.cell(row=row, column=1, value="No errors in this period.").font = SUBTITLE_FONT
        row += 2
    row += 1
    row = write_section_header(ws, row, "Error Trend Over Time")
    trend_chart = make_errors_trend_chart(models_data)
    if trend_chart:
        row = insert_chart_image(ws, row, 1, trend_chart)
    else:
        ws.cell(row=row, column=1, value="No error trends to display.").font = SUBTITLE_FONT
        row += 2

    row += 1
    write_conclusion(ws, row, _conclude_reliability(models_data))
    return ws

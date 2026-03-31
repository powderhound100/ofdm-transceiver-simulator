"""Generate SVG BER charts from sweep data JSONs for the HTML report.

Loads from up to 3 JSON sources:
  - ber_sweep_data.json       (Python simulation)
  - rust_ber_sweep_data.json  (Rust simulation)
  - rtl_ber_sweep_data.json   (RTL co-simulation)

Produces 10 SVG charts in 4 groups:
  Group A -- Modulation Comparison (LMMSE+MMSE):
    A1: Flat channel, all 8 modulations
    A2: TU-6 channel, all 8 modulations
  Group B -- Channel Comparison (LMMSE+MMSE):
    B1: QPSK across all 10 channels
    B2: 64-QAM across all 10 channels
    B3: 256-QAM across all 10 channels
  Group C -- Estimator Comparison (TU-6):
    C1: QPSK: LS vs LS-Improved vs LMMSE
    C2: 64-QAM: LS vs LS-Improved vs LMMSE
  Group D -- Cross-Implementation (Python vs Rust vs RTL):
    D1: QPSK Flat LMMSE
    D2: 64-QAM Flat LMMSE
    D3: 256-QAM TU-6 LMMSE

X-axis: Eb/N0 (dB), -5 to 30.
Y-axis: BER on log scale (1e0 to 1e-5).
Waterfall curves: monotonically non-increasing (enforced).
"""
import json, math, os, sys

# =============================================================================
# Color palette (Catppuccin extended)
# =============================================================================
MOD_COLORS = {
    "BPSK":    "#a6e3a1",
    "QPSK":    "#89b4fa",
    "16QAM":   "#f9e2af",
    "64QAM":   "#f38ba8",
    "256QAM":  "#cba6f7",
    "512QAM":  "#fab387",
    "1024QAM": "#94e2d5",
    "2048QAM": "#eba0ac",
}

EST_COLORS = {
    "LS":          "#f38ba8",
    "LS_improved": "#f9e2af",
    "LMMSE":       "#a6e3a1",
}

IMPL_STYLES = {
    "Python": False,
    "Rust":   "8,4",
    "RTL":    "3,3",
}

CH_DASH = {
    "flat":       False,
    "two_tap":    "8,4",
    "tu6":        "4,4",
    "cost207_ra": "12,4",
    "cost207_ht": "2,6",
    "brazil_a":   "8,2,2,2",
    "brazil_b":   "12,2",
    "brazil_c":   "6,6",
    "brazil_d":   "2,2",
    "brazil_e":   "16,4",
}

# Pretty channel names for legends
CH_LABELS = {
    "flat":       "Flat (AWGN)",
    "two_tap":    "Two-Tap",
    "tu6":        "TU-6",
    "cost207_ra": "COST207-RA",
    "cost207_ht": "COST207-HT",
    "brazil_a":   "Brazil-A",
    "brazil_b":   "Brazil-B",
    "brazil_c":   "Brazil-C",
    "brazil_d":   "Brazil-D",
    "brazil_e":   "Brazil-E",
}

# All 10 channel keys in order
ALL_CHANNELS = [
    "flat", "two_tap", "tu6", "cost207_ra", "cost207_ht",
    "brazil_a", "brazil_b", "brazil_c", "brazil_d", "brazil_e",
]

# All 8 modulation keys in order
ALL_MODS = ["BPSK", "QPSK", "16QAM", "64QAM", "256QAM", "512QAM", "1024QAM", "2048QAM"]


# =============================================================================
# Data loading
# =============================================================================

def load_json(path):
    """Load JSON file, return empty dict if missing."""
    if os.path.exists(path):
        with open(path, "r") as f:
            return json.load(f)
    return {}


def load_all_data():
    """Load all three JSON sources into a unified dict."""
    base = os.path.dirname(os.path.abspath(__file__))
    py_data   = load_json(os.path.join(base, "ber_sweep_data.json"))
    rust_data = load_json(os.path.join(base, "rust_ber_sweep_data.json"))
    rtl_data  = load_json(os.path.join(base, "rtl_ber_sweep_data.json"))
    return py_data, rust_data, rtl_data


# =============================================================================
# SVG primitives
# =============================================================================

def enforce_monotonic(points):
    """Ensure BER is monotonically non-increasing with SNR (ascending SNR order)."""
    pts = sorted(points, key=lambda p: p["snr_db"])
    out = [pts[0]]
    for i in range(1, len(pts)):
        ber = min(pts[i]["ber_coded"], out[-1]["ber_coded"])
        out.append({**pts[i], "ber_coded": ber})
    return out


def ber_to_y(ber, y_top, y_bot, ber_max=1e0, ber_min=1e-5):
    """Map BER (log scale) to SVG y coordinate."""
    if ber <= 0:
        ber = ber_min / 10
    log_ber = math.log10(max(ber, ber_min / 10))
    log_max = math.log10(ber_max)
    log_min = math.log10(ber_min)
    frac = (log_ber - log_max) / (log_min - log_max)
    return y_top + frac * (y_bot - y_top)


def snr_to_x(snr, x_left, x_right, snr_min, snr_max):
    """Map SNR (dB) to SVG x coordinate."""
    frac = (snr - snr_min) / (snr_max - snr_min)
    return x_left + frac * (x_right - x_left)


def make_polyline(curve, color, snr_min, snr_max, width, height, dash=False):
    """Generate SVG polyline + circles for a BER curve."""
    x_left  = 70
    x_right = width - 30
    y_top   = 30
    y_bot   = height - 50

    pts = enforce_monotonic(curve)
    coords = []
    circles = []
    for p in pts:
        if p["snr_db"] < snr_min or p["snr_db"] > snr_max:
            continue
        ber = p["ber_coded"]
        if ber <= 0:
            continue
        x = snr_to_x(p["snr_db"], x_left, x_right, snr_min, snr_max)
        y = ber_to_y(ber, y_top, y_bot)
        coords.append(f"{x:.1f},{y:.1f}")
        circles.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="{color}"/>')

    if not coords:
        return ""

    dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
    lines = [f'<polyline points="{" ".join(coords)}" fill="none" stroke="{color}" stroke-width="2.5"{dash_attr} />']
    lines.extend(circles)
    return "\n".join(lines)


def make_grid(title, snr_min, snr_max, width, height):
    """Generate SVG grid, axes, labels."""
    x_left  = 70
    x_right = width - 30
    y_top   = 30
    y_bot   = height - 50
    plot_w  = x_right - x_left
    plot_h  = y_bot - y_top

    lines = []
    lines.append(f'<rect width="{width}" height="{height}" fill="#181825" rx="8"/>')
    lines.append(f'<rect x="{x_left}" y="{y_top}" width="{plot_w}" height="{plot_h}" fill="#1e1e2e" stroke="#313244"/>')
    lines.append(f'<text x="{width/2:.0f}" y="20" text-anchor="middle" fill="#cdd6f4" font-size="14" font-family="sans-serif" font-weight="bold">{title}</text>')

    # Y-axis grid (BER decades: 1e0 to 1e-5)
    for decade in range(0, -6, -1):
        y = ber_to_y(10**decade, y_top, y_bot)
        lines.append(f'<line x1="{x_left}" y1="{y:.0f}" x2="{x_right}" y2="{y:.0f}" stroke="#313244" stroke-dasharray="4,4"/>')
        lines.append(f'<text x="{x_left - 8}" y="{y+4:.0f}" text-anchor="end" fill="#a6adc8" font-size="11" font-family="monospace">1e{decade}</text>')

    # X-axis grid
    span = snr_max - snr_min
    step = 5 if span <= 40 else 10
    tick = snr_min
    while tick <= snr_max:
        x = snr_to_x(tick, x_left, x_right, snr_min, snr_max)
        lines.append(f'<line x1="{x:.0f}" y1="{y_top}" x2="{x:.0f}" y2="{y_bot}" stroke="#313244" stroke-dasharray="4,4"/>')
        lines.append(f'<text x="{x:.0f}" y="{y_bot + 16}" text-anchor="middle" fill="#a6adc8" font-size="11" font-family="monospace">{tick:.0f}</text>')
        tick += step

    # Axis labels
    lines.append(f'<text x="{width/2:.0f}" y="{height - 5}" text-anchor="middle" fill="#cdd6f4" font-size="12" font-family="sans-serif">Eb/N0 (dB)</text>')
    lines.append(f'<text x="15" y="{(y_top + y_bot) / 2:.0f}" text-anchor="middle" fill="#cdd6f4" font-size="12" font-family="sans-serif" transform="rotate(-90,15,{(y_top + y_bot) / 2:.0f})">Bit Error Rate</text>')

    return "\n".join(lines)


def make_legend_entry(x, y, color, label, dash=False):
    """Generate SVG legend line + circle + label."""
    dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
    return (f'<line x1="{x}" y1="{y}" x2="{x+20}" y2="{y}" stroke="{color}" stroke-width="2.5"{dash_attr} />\n'
            f'<circle cx="{x+10}" cy="{y}" r="3" fill="{color}"/>\n'
            f'<text x="{x+25}" y="{y+4}" fill="#cdd6f4" font-size="11" font-family="sans-serif">{label}</text>')


# =============================================================================
# Core chart generator
# =============================================================================

def generate_chart(title, curves, snr_min=-5, snr_max=30, width=900, height=500):
    """Generate a complete SVG chart.

    Args:
        title: Chart title string.
        curves: list of (data_key, json_source_dict, color, label, dash_pattern_or_False).
        snr_min: Minimum SNR on x-axis.
        snr_max: Maximum SNR on x-axis.
        width: SVG width in pixels.
        height: SVG height in pixels.

    Returns:
        SVG string.
    """
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" style="max-width:{width}px;">']
    svg.append(make_grid(title, snr_min, snr_max, width, height))

    # Legend positioning
    legend_x = width - 220
    legend_y = 45
    legend_spacing = 18

    legend_entries = []
    for data_key, json_src, color, label, dash in curves:
        curve_data = None
        # Handle BPSK_baseline special key
        if data_key in json_src:
            raw = json_src[data_key]
            # Normalize: BPSK_baseline uses "ber" key instead of "ber_coded"
            if raw and "ber" in raw[0] and "ber_coded" not in raw[0]:
                curve_data = [{"snr_db": p["snr_db"], "ber_coded": p["ber"]} for p in raw]
            else:
                curve_data = raw

        if curve_data and len(curve_data) > 0:
            svg.append(make_polyline(curve_data, color, snr_min, snr_max, width, height, dash=dash))
        legend_entries.append((color, label, dash))

    # Render legend
    for i, (color, label, dash) in enumerate(legend_entries):
        svg.append(make_legend_entry(legend_x, legend_y + i * legend_spacing, color, label, dash=dash))

    svg.append("</svg>")
    return "\n".join(svg)


# =============================================================================
# Chart definitions
# =============================================================================

def build_all_charts(py_data, rust_data, rtl_data):
    """Build all 10 charts. Returns list of (filename, svg_string, group_label)."""
    charts = []

    # -------------------------------------------------------------------------
    # Group A: Modulation Comparison (LMMSE+MMSE)
    # -------------------------------------------------------------------------

    # A1: Flat channel, all 8 modulations
    curves_a1 = []
    for mod in ALL_MODS:
        # Try Python keys: "{mod}_flat_LMMSE" or legacy "{mod}_flat" or "BPSK_baseline"
        if mod == "BPSK":
            curves_a1.append(("BPSK_baseline", py_data, MOD_COLORS[mod], "BPSK", False))
        else:
            key = f"{mod}_flat_LMMSE"
            key_legacy = f"{mod}_flat"
            src = py_data
            if key in src:
                curves_a1.append((key, src, MOD_COLORS[mod], mod, False))
            elif key_legacy in src:
                curves_a1.append((key_legacy, src, MOD_COLORS[mod], mod, False))

    charts.append(("ber_chart_a1.svg",
                    generate_chart("BER vs Eb/N0 -- Flat Channel, All Modulations (LMMSE+MMSE)",
                                   curves_a1, width=900, height=500),
                    "Group A: Modulation Comparison"))

    # A2: TU-6 channel, all 8 modulations
    curves_a2 = []
    for mod in ALL_MODS:
        if mod == "BPSK":
            key = "BPSK_tu6_LMMSE"
            key_legacy = "BPSK_tu6"
            if key in py_data:
                curves_a2.append((key, py_data, MOD_COLORS[mod], "BPSK", False))
            elif key_legacy in py_data:
                curves_a2.append((key_legacy, py_data, MOD_COLORS[mod], "BPSK", False))
        else:
            key = f"{mod}_tu6_LMMSE"
            key_legacy = f"{mod}_tu6"
            if key in py_data:
                curves_a2.append((key, py_data, MOD_COLORS[mod], mod, False))
            elif key_legacy in py_data:
                curves_a2.append((key_legacy, py_data, MOD_COLORS[mod], mod, False))

    charts.append(("ber_chart_a2.svg",
                    generate_chart("BER vs Eb/N0 -- TU-6 Channel, All Modulations (LMMSE+MMSE)",
                                   curves_a2, width=900, height=500),
                    "Group A: Modulation Comparison"))

    # -------------------------------------------------------------------------
    # Group B: Channel Comparison (LMMSE+MMSE)
    # -------------------------------------------------------------------------

    for mod, suffix in [("QPSK", "b1"), ("64QAM", "b2"), ("256QAM", "b3")]:
        curves_b = []
        for ch in ALL_CHANNELS:
            key = f"{mod}_{ch}_LMMSE"
            key_legacy = f"{mod}_{ch}"
            color = MOD_COLORS.get(mod, "#89b4fa")
            dash = CH_DASH.get(ch, False)
            label = f"{CH_LABELS.get(ch, ch)}"
            if key in py_data:
                curves_b.append((key, py_data, color, label, dash))
            elif key_legacy in py_data:
                curves_b.append((key_legacy, py_data, color, label, dash))

        # Use larger chart for >6 curves
        w = 900 if len(curves_b) > 6 else 700
        h = 500 if len(curves_b) > 6 else 400
        charts.append((f"ber_chart_{suffix}.svg",
                        generate_chart(f"BER vs Eb/N0 -- {mod} Across All Channels (LMMSE+MMSE)",
                                       curves_b, width=w, height=h),
                        "Group B: Channel Comparison"))

    # -------------------------------------------------------------------------
    # Group C: Estimator Comparison (TU-6)
    # -------------------------------------------------------------------------

    for mod, suffix in [("QPSK", "c1"), ("64QAM", "c2")]:
        curves_c = []
        for est in ["LS", "LS_improved", "LMMSE"]:
            key = f"{mod}_tu6_{est}"
            key_legacy = f"{mod}_tu6"
            color = EST_COLORS.get(est, "#89b4fa")
            dash = False
            label = f"{est.replace('_', '-')}"
            if key in py_data:
                curves_c.append((key, py_data, color, label, dash))
            elif est == "LS" and key_legacy in py_data:
                # Legacy data used default LS estimator
                curves_c.append((key_legacy, py_data, color, label, dash))

        charts.append((f"ber_chart_{suffix}.svg",
                        generate_chart(f"BER vs Eb/N0 -- {mod} TU-6: Estimator Comparison",
                                       curves_c, width=700, height=400),
                        "Group C: Estimator Comparison"))

    # -------------------------------------------------------------------------
    # Group D: Cross-Implementation (Python vs Rust vs RTL)
    # -------------------------------------------------------------------------

    d_configs = [
        ("QPSK",   "flat", "d1"),
        ("64QAM",  "flat", "d2"),
        ("256QAM", "tu6",  "d3"),
    ]

    for mod, ch, suffix in d_configs:
        curves_d = []

        # Python
        py_key = f"{mod}_{ch}_LMMSE"
        py_key_legacy = f"{mod}_{ch}"
        if py_key in py_data:
            curves_d.append((py_key, py_data, "#89b4fa", "Python", IMPL_STYLES["Python"]))
        elif py_key_legacy in py_data:
            curves_d.append((py_key_legacy, py_data, "#89b4fa", "Python", IMPL_STYLES["Python"]))

        # Rust
        rust_key = f"{mod}_{ch}_LMMSE_Rust"
        rust_key2 = f"{mod}_{ch}_LMMSE"
        if rust_key in rust_data:
            curves_d.append((rust_key, rust_data, "#f9e2af", "Rust", IMPL_STYLES["Rust"]))
        elif rust_key2 in rust_data:
            curves_d.append((rust_key2, rust_data, "#f9e2af", "Rust", IMPL_STYLES["Rust"]))

        # RTL
        rtl_key = f"{mod}_{ch}_LMMSE_RTL"
        if rtl_key in rtl_data:
            curves_d.append((rtl_key, rtl_data, "#a6e3a1", "RTL (iverilog)", IMPL_STYLES["RTL"]))

        ch_label = CH_LABELS.get(ch, ch)
        charts.append((f"ber_chart_{suffix}.svg",
                        generate_chart(f"BER vs Eb/N0 -- {mod} {ch_label} LMMSE: Python vs Rust vs RTL",
                                       curves_d, width=700, height=400),
                        "Group D: Cross-Implementation"))

    return charts


# =============================================================================
# Main
# =============================================================================

def main():
    py_data, rust_data, rtl_data = load_all_data()

    # Report loaded data
    print(f"Python data:  {len(py_data)} curves ({', '.join(sorted(py_data.keys()))})")
    print(f"Rust data:    {len(rust_data)} curves ({', '.join(sorted(rust_data.keys()))})")
    print(f"RTL data:     {len(rtl_data)} curves ({', '.join(sorted(rtl_data.keys()))})")

    charts = build_all_charts(py_data, rust_data, rtl_data)

    # Save individual SVGs to docs/
    base_dir = os.path.dirname(os.path.abspath(__file__))
    docs_dir = os.path.join(os.path.dirname(base_dir), "docs")
    if not os.path.exists(docs_dir):
        os.makedirs(docs_dir)

    for filename, svg_content, group in charts:
        svg_path = os.path.join(docs_dir, filename)
        with open(svg_path, "w") as f:
            f.write(svg_content)
        print(f"  Saved {svg_path}")

    # Save combined HTML
    html_path = os.path.join(base_dir, "ber_charts_output.html")
    with open(html_path, "w") as f:
        f.write('<!DOCTYPE html>\n<html lang="en">\n<head>\n')
        f.write('<meta charset="UTF-8">\n')
        f.write('<title>OFDM Transceiver BER Charts</title>\n')
        f.write('<style>body{background:#11111b;color:#cdd6f4;font-family:sans-serif;max-width:960px;margin:0 auto;padding:20px}')
        f.write('h1{text-align:center}h2{color:#89b4fa;border-bottom:1px solid #313244;padding-bottom:8px}')
        f.write('svg{display:block;margin:16px auto}</style>\n')
        f.write('</head>\n<body>\n')
        f.write('<h1>OFDM Transceiver Simulator &mdash; BER Charts</h1>\n')

        current_group = None
        for filename, svg_content, group in charts:
            if group != current_group:
                f.write(f'\n<h2>{group}</h2>\n')
                current_group = group
            f.write(f'<!-- {filename} -->\n')
            f.write(svg_content)
            f.write('\n\n')

        f.write('</body>\n</html>\n')

    print(f"\n  Saved combined HTML: {html_path}")
    print(f"  Total charts: {len(charts)}")

    # Summary of curves per chart
    for filename, _, group in charts:
        print(f"    {filename} ({group})")


if __name__ == "__main__":
    main()

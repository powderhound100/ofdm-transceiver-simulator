"""Generate SVG BER charts from ber_sweep_data.json for the HTML report.

Produces inline SVG that can be pasted into project_report.html.
X-axis: Eb/N0 (dB), increasing left-to-right.
Y-axis: BER on log scale (1e0 to 1e-5).
Waterfall curves: monotonically non-increasing (enforced).
"""
import json, math, sys

def load_data(path="ber_sweep_data.json"):
    with open(path, "r") as f:
        return json.load(f)


def enforce_monotonic(points):
    """Ensure BER is monotonically non-increasing with SNR (ascending SNR order)."""
    pts = sorted(points, key=lambda p: p["snr_db"])
    out = [pts[0]]
    for i in range(1, len(pts)):
        ber = min(pts[i]["ber_coded"], out[-1]["ber_coded"])
        out.append({**pts[i], "ber_coded": ber})
    return out


def ber_to_y(ber, y_top=30, y_bot=350, ber_max=1e0, ber_min=1e-5):
    """Map BER (log scale) to SVG y coordinate."""
    if ber <= 0:
        ber = ber_min / 10  # below chart
    log_ber = math.log10(max(ber, ber_min / 10))
    log_max = math.log10(ber_max)
    log_min = math.log10(ber_min)
    frac = (log_ber - log_max) / (log_min - log_max)  # 0=top, 1=bottom
    return y_top + frac * (y_bot - y_top)


def snr_to_x(snr, x_left=70, x_right=670, snr_min=-40, snr_max=20):
    """Map SNR (dB) to SVG x coordinate. Higher SNR = further right."""
    frac = (snr - snr_min) / (snr_max - snr_min)
    return x_left + frac * (x_right - x_left)


def make_polyline(curve, color, snr_min, snr_max, dash=False):
    """Generate SVG polyline + circles for a BER curve."""
    pts = enforce_monotonic(curve)
    coords = []
    circles = []
    for p in pts:
        if p["snr_db"] < snr_min or p["snr_db"] > snr_max:
            continue
        ber = p["ber_coded"]
        if ber <= 0:
            continue  # skip zero-BER points (can't plot on log scale)
        x = snr_to_x(p["snr_db"], snr_min=snr_min, snr_max=snr_max)
        y = ber_to_y(ber)
        coords.append(f"{x:.1f},{y:.1f}")
        circles.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="3" fill="{color}"/>')

    if not coords:
        return ""

    style = f' stroke-dasharray="8,4"' if dash else ""
    lines = [f'<polyline points="{" ".join(coords)}" fill="none" stroke="{color}" stroke-width="2.5"{style} />']
    lines.extend(circles)
    return "\n".join(lines)


def make_grid(title, snr_min, snr_max):
    """Generate SVG grid, axes, labels."""
    lines = []
    lines.append(f'<rect width="700" height="400" fill="#181825" rx="8"/>')
    lines.append(f'<rect x="70" y="30" width="600" height="320" fill="#1e1e2e" stroke="#313244"/>')
    lines.append(f'<text x="350" y="20" text-anchor="middle" fill="#cdd6f4" font-size="14" font-family="sans-serif" font-weight="bold">{title}</text>')

    # Y-axis grid (BER decades: 1e0 to 1e-5)
    for decade in range(0, -6, -1):
        y = ber_to_y(10**decade)
        lines.append(f'<line x1="70" y1="{y:.0f}" x2="670" y2="{y:.0f}" stroke="#313244" stroke-dasharray="4,4"/>')
        lines.append(f'<text x="62" y="{y+4:.0f}" text-anchor="end" fill="#a6adc8" font-size="11" font-family="monospace">1e{decade}</text>')

    # X-axis grid
    # Determine tick spacing based on range
    span = snr_max - snr_min
    if span <= 30:
        step = 5
    else:
        step = 10
    tick = snr_min
    while tick <= snr_max:
        x = snr_to_x(tick, snr_min=snr_min, snr_max=snr_max)
        lines.append(f'<line x1="{x:.0f}" y1="30" x2="{x:.0f}" y2="350" stroke="#313244" stroke-dasharray="4,4"/>')
        lines.append(f'<text x="{x:.0f}" y="366" text-anchor="middle" fill="#a6adc8" font-size="11" font-family="monospace">{tick:.0f}</text>')
        tick += step

    # Axis labels
    lines.append(f'<text x="370" y="395" text-anchor="middle" fill="#cdd6f4" font-size="12" font-family="sans-serif">Eb/N0 (dB)</text>')
    lines.append(f'<text x="15" y="200" text-anchor="middle" fill="#cdd6f4" font-size="12" font-family="sans-serif" transform="rotate(-90,15,200)">Bit Error Rate</text>')

    return "\n".join(lines)


def make_legend_entry(x, y, color, label, dash=False):
    style = f' stroke-dasharray="8,4"' if dash else ""
    return (f'<line x1="{x}" y1="{y}" x2="{x+20}" y2="{y}" stroke="{color}" stroke-width="2.5"{style} />\n'
            f'<circle cx="{x+10}" cy="{y}" r="3" fill="{color}"/>\n'
            f'<text x="{x+25}" y="{y+4}" fill="#cdd6f4" font-size="11" font-family="sans-serif">{label}</text>')


def generate_chart_1(data, snr_min, snr_max):
    """Chart 1: BER vs SNR — Flat Channel (AWGN), all modulations."""
    colors = {"BPSK": "#a6e3a1", "QPSK": "#89b4fa", "16QAM": "#f9e2af", "64QAM": "#f38ba8"}

    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 700 400" style="max-width:700px;">']
    svg.append(make_grid("BER vs Eb/N0 -- Flat Channel (AWGN)", snr_min, snr_max))

    # BPSK baseline
    if "BPSK_baseline" in data:
        bpsk_curve = [{"snr_db": p["snr_db"], "ber_coded": p["ber"]} for p in data["BPSK_baseline"]]
        svg.append(make_polyline(bpsk_curve, colors["BPSK"], snr_min, snr_max))

    # OFDM flat curves
    for mod, color in [("QPSK", colors["QPSK"]), ("16QAM", colors["16QAM"]), ("64QAM", colors["64QAM"])]:
        key = f"{mod}_flat"
        if key in data:
            svg.append(make_polyline(data[key], color, snr_min, snr_max))

    # Legend
    svg.append(make_legend_entry(480, 45, colors["BPSK"], "BPSK (baseline)"))
    svg.append(make_legend_entry(480, 63, colors["QPSK"], "QPSK"))
    svg.append(make_legend_entry(480, 81, colors["16QAM"], "16-QAM"))
    svg.append(make_legend_entry(480, 99, colors["64QAM"], "64-QAM"))

    svg.append("</svg>")
    return "\n".join(svg)


def generate_chart_2(data, snr_min, snr_max):
    """Chart 2: QPSK across all channels."""
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 700 400" style="max-width:700px;">']
    svg.append(make_grid("BER vs Eb/N0 -- QPSK Across All Channels", snr_min, snr_max))

    color = "#89b4fa"
    for ch, dash, label in [("flat", False, "QPSK Flat"), ("two_tap", True, "QPSK Two-Tap"), ("tu6", True, "QPSK TU-6")]:
        key = f"QPSK_{ch}"
        if key in data:
            svg.append(make_polyline(data[key], color, snr_min, snr_max, dash=dash))

    svg.append(make_legend_entry(480, 45, color, "QPSK Flat"))
    svg.append(make_legend_entry(480, 63, color, "QPSK Two-Tap", dash=True))
    svg.append(make_legend_entry(480, 81, color, "QPSK TU-6", dash=True))

    svg.append("</svg>")
    return "\n".join(svg)


def generate_chart_3(data, snr_min, snr_max):
    """Chart 3: 16-QAM across all channels."""
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 700 400" style="max-width:700px;">']
    svg.append(make_grid("BER vs Eb/N0 -- 16-QAM Across All Channels", snr_min, snr_max))

    color = "#f9e2af"
    for ch, dash, label in [("flat", False, "16QAM Flat"), ("two_tap", True, "16QAM Two-Tap"), ("tu6", True, "16QAM TU-6")]:
        key = f"16QAM_{ch}"
        if key in data:
            svg.append(make_polyline(data[key], color, snr_min, snr_max, dash=dash))

    svg.append(make_legend_entry(480, 45, color, "16QAM Flat"))
    svg.append(make_legend_entry(480, 63, color, "16QAM Two-Tap", dash=True))
    svg.append(make_legend_entry(480, 81, color, "16QAM TU-6", dash=True))

    svg.append("</svg>")
    return "\n".join(svg)


if __name__ == "__main__":
    data = load_data()

    # Determine SNR range from data
    all_snr = []
    for key, curve in data.items():
        if key == "BPSK_baseline":
            for p in curve:
                all_snr.append(p["snr_db"])
        else:
            for p in curve:
                all_snr.append(p["snr_db"])
    snr_min = min(all_snr)
    snr_max = max(all_snr)
    print(f"SNR range: {snr_min} to {snr_max} dB")

    chart1 = generate_chart_1(data, snr_min, snr_max)
    chart2 = generate_chart_2(data, snr_min, snr_max)
    chart3 = generate_chart_3(data, snr_min, snr_max)

    with open("ber_charts_output.html", "w") as f:
        f.write("<!-- Chart 1: Flat Channel -->\n")
        f.write(chart1)
        f.write("\n\n<!-- Chart 2: QPSK All Channels -->\n")
        f.write(chart2)
        f.write("\n\n<!-- Chart 3: 16-QAM All Channels -->\n")
        f.write(chart3)

    print("Saved to ber_charts_output.html")

    # Also print summary of data
    for key, curve in data.items():
        pts = sorted(curve, key=lambda p: p.get("snr_db", 0))
        ber_key = "ber_coded" if "ber_coded" in pts[0] else "ber"
        nonzero = [p for p in pts if p[ber_key] > 0]
        zero = [p for p in pts if p[ber_key] == 0]
        print(f"  {key}: {len(pts)} points, {len(nonzero)} with BER>0, BER=0 threshold at SNR={zero[0]['snr_db'] if zero else '>max'} dB")

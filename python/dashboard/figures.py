"""Figure-building functions for the 6-panel dashboard."""
from __future__ import annotations
import numpy as np
import plotly.graph_objects as go
from plotly.subplots import make_subplots


PLOT_BG = "#1e1e2e"
PAPER_BG = "#181825"
GRID_COLOR = "#313244"
TEXT_COLOR = "#cdd6f4"
ACCENT_1 = "#89b4fa"   # blue
ACCENT_2 = "#f38ba8"   # red/pink
ACCENT_3 = "#a6e3a1"   # green
ACCENT_4 = "#f9e2af"   # yellow


def _base_layout(title: str) -> dict:
    return dict(
        title=dict(text=title, font=dict(color=TEXT_COLOR, size=14)),
        paper_bgcolor=PAPER_BG,
        plot_bgcolor=PLOT_BG,
        font=dict(color=TEXT_COLOR, size=11),
        margin=dict(l=50, r=20, t=40, b=40),
        xaxis=dict(gridcolor=GRID_COLOR, zerolinecolor=GRID_COLOR),
        yaxis=dict(gridcolor=GRID_COLOR, zerolinecolor=GRID_COLOR),
    )


def make_constellation(symbols: np.ndarray, title: str,
                       ref_points: np.ndarray | None = None) -> go.Figure:
    """IQ constellation scatter plot."""
    fig = go.Figure()

    # Data points
    fig.add_trace(go.Scattergl(
        x=symbols.real, y=symbols.imag,
        mode='markers',
        marker=dict(size=3, color=ACCENT_1, opacity=0.6),
        name='Received',
    ))

    # Reference constellation points
    if ref_points is not None:
        fig.add_trace(go.Scatter(
            x=ref_points.real, y=ref_points.imag,
            mode='markers',
            marker=dict(size=10, color=ACCENT_2, symbol='x', line=dict(width=2)),
            name='Ideal',
        ))

    layout = _base_layout(title)
    layout['xaxis']['title'] = 'In-Phase (I)'
    layout['yaxis']['title'] = 'Quadrature (Q)'
    layout['yaxis']['scaleanchor'] = 'x'
    layout['showlegend'] = False
    fig.update_layout(**layout)
    return fig


def make_psd(signal: np.ndarray, sample_rate: float, title: str = "Power Spectral Density") -> go.Figure:
    """Power spectral density plot using Welch-like windowed FFT."""
    n = len(signal)
    seg_len = min(1024, n)
    n_segments = max(1, n // seg_len)

    psd_accum = np.zeros(seg_len)
    for i in range(n_segments):
        seg = signal[i * seg_len:(i + 1) * seg_len]
        if len(seg) < seg_len:
            break
        window = np.hanning(seg_len)
        windowed = seg.astype(np.complex128) * window
        spectrum = np.fft.fftshift(np.fft.fft(windowed))
        psd_accum += np.abs(spectrum) ** 2

    psd_accum /= n_segments
    psd_db = 10 * np.log10(psd_accum + 1e-12)

    freqs = np.fft.fftshift(np.fft.fftfreq(seg_len, 1.0 / sample_rate)) / 1e6

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=freqs, y=psd_db,
        mode='lines',
        line=dict(color=ACCENT_3, width=1.5),
        fill='tozeroy',
        fillcolor='rgba(166, 227, 161, 0.1)',
    ))

    layout = _base_layout(title)
    layout['xaxis']['title'] = 'Frequency (MHz)'
    layout['yaxis']['title'] = 'Power (dB)'
    fig.update_layout(**layout)
    return fig


def make_channel_response(h_true: np.ndarray, h_est: np.ndarray,
                          sample_rate: float) -> go.Figure:
    """Channel frequency response: true vs estimated."""
    n = len(h_true)
    freqs = np.fft.fftshift(np.fft.fftfreq(n, 1.0 / sample_rate)) / 1e6

    h_true_shift = np.fft.fftshift(h_true)
    h_est_shift = np.fft.fftshift(h_est)

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=freqs, y=20 * np.log10(np.abs(h_true_shift) + 1e-12),
        mode='lines',
        line=dict(color=ACCENT_1, width=2),
        name='True H(f)',
    ))
    fig.add_trace(go.Scatter(
        x=freqs, y=20 * np.log10(np.abs(h_est_shift) + 1e-12),
        mode='lines',
        line=dict(color=ACCENT_2, width=2, dash='dash'),
        name='Estimated H(f)',
    ))

    layout = _base_layout("Channel Frequency Response")
    layout['xaxis']['title'] = 'Frequency (MHz)'
    layout['yaxis']['title'] = '|H(f)| (dB)'
    layout['showlegend'] = True
    layout['legend'] = dict(bgcolor='rgba(0,0,0,0)', font=dict(color=TEXT_COLOR))
    fig.update_layout(**layout)
    return fig


def make_ber_waterfall(ber_data: list[dict]) -> go.Figure:
    """BER vs SNR waterfall curve."""
    snrs = [d['snr_db'] for d in ber_data]
    bers = [max(d['ber'], 1e-7) for d in ber_data]
    fers = [max(d['fer'], 1e-7) for d in ber_data]

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=snrs, y=bers,
        mode='lines+markers',
        line=dict(color=ACCENT_1, width=2),
        marker=dict(size=8),
        name='BER',
    ))
    fig.add_trace(go.Scatter(
        x=snrs, y=fers,
        mode='lines+markers',
        line=dict(color=ACCENT_2, width=2, dash='dash'),
        marker=dict(size=8),
        name='FER',
    ))

    layout = _base_layout("BER / FER Waterfall")
    layout['xaxis']['title'] = 'SNR (dB)'
    layout['yaxis']['title'] = 'Error Rate'
    layout['yaxis']['type'] = 'log'
    layout['yaxis']['range'] = [-7, 0]
    layout['showlegend'] = True
    layout['legend'] = dict(bgcolor='rgba(0,0,0,0)', font=dict(color=TEXT_COLOR))
    fig.update_layout(**layout)
    return fig


def make_convergence(iteration_data: list, code_m: int) -> go.Figure:
    """LDPC decoder convergence: syndrome weight and bit changes per iteration."""
    if not iteration_data:
        fig = go.Figure()
        fig.update_layout(**_base_layout("LDPC Convergence (no data)"))
        return fig

    iters = list(range(1, len(iteration_data) + 1))

    # Syndrome weight: count of unsatisfied checks
    syndrome_weights = []
    for it in iteration_data:
        hard = it['hard_bits']
        # Count how many checks fail (approximate from syndrome_pass)
        if it['syndrome_pass']:
            syndrome_weights.append(0)
        else:
            # Estimate from posterior changes
            syndrome_weights.append(code_m)  # placeholder

    # Better metric: posterior magnitude (convergence indicator)
    posterior_means = [float(np.mean(np.abs(it['posterior']))) for it in iteration_data]

    fig = go.Figure()
    fig.add_trace(go.Scatter(
        x=iters, y=posterior_means,
        mode='lines+markers',
        line=dict(color=ACCENT_3, width=2),
        marker=dict(size=5),
        name='Mean |Posterior|',
    ))

    # Mark convergence point
    for i, it in enumerate(iteration_data):
        if it['syndrome_pass']:
            fig.add_vline(x=i+1, line=dict(color=ACCENT_4, width=2, dash='dash'),
                         annotation_text="Converged")
            break

    layout = _base_layout("LDPC Decoder Convergence")
    layout['xaxis']['title'] = 'Iteration'
    layout['yaxis']['title'] = 'Mean |Posterior LLR|'
    layout['showlegend'] = False
    fig.update_layout(**layout)
    return fig

"""ATSC 3.0 OFDM + LDPC Decoder Dashboard.

Run: python dashboard.py
Opens browser to http://127.0.0.1:8050
"""
from __future__ import annotations

import sys
import os

# Ensure python/ is on the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import dash
    from dash import dcc, html, Input, Output, State, callback
    import dash_bootstrap_components as dbc
except ImportError:
    print("Dashboard dependencies missing. Install with:")
    print("  pip install plotly dash dash-bootstrap-components")
    sys.exit(1)

import numpy as np
from ofdm.simulation import run_ofdm_chain
from ofdm.modulator import CONSTELLATIONS
from ofdm.params import OfdmParams
from dashboard.figures import (
    make_constellation, make_psd, make_channel_response,
    make_ber_waterfall, make_convergence,
    PAPER_BG, TEXT_COLOR, ACCENT_1, ACCENT_3
)

# ---------------------------------------------------------------------------
# Pre-compute initial data
# ---------------------------------------------------------------------------
print("Running initial simulation...")
INITIAL_RESULT = run_ofdm_chain(snr_db=5.0, modulation="QPSK", channel_model="flat")
print(f"  Done. Converged={INITIAL_RESULT.ldpc_converged}, "
      f"iters={INITIAL_RESULT.ldpc_iterations}, BER={INITIAL_RESULT.ber_coded:.4e}")

# Pre-compute BER sweep (quick, 5 points)
print("Computing BER sweep...")
BER_DATA = []
for snr in [-2.0, 0.0, 2.0, 4.0, 6.0, 8.0, 10.0]:
    r = run_ofdm_chain(snr_db=snr, modulation="QPSK", channel_model="flat", seed=42)
    BER_DATA.append({
        'snr_db': snr,
        'ber': r.ber_coded,
        'fer': 1.0 if not r.ldpc_converged else 0.0,
        'avg_iter': r.ldpc_iterations,
    })
    print(f"  SNR={snr:>5.1f} dB: BER={r.ber_coded:.4e}, iters={r.ldpc_iterations}")
print("  Done.\n")

# ---------------------------------------------------------------------------
# Dash app
# ---------------------------------------------------------------------------
app = dash.Dash(
    __name__,
    external_stylesheets=[dbc.themes.CYBORG],
    title="ATSC 3.0 OFDM + LDPC Dashboard",
)

# --- Controls ---
controls = dbc.Card([
    dbc.CardBody([
        dbc.Row([
            dbc.Col([
                html.Label("SNR (dB)", style={'color': TEXT_COLOR, 'fontWeight': 'bold'}),
                dcc.Slider(
                    id='snr-slider', min=-3, max=15, step=0.5, value=5.0,
                    marks={i: f'{i}' for i in range(-3, 16, 3)},
                    tooltip={"placement": "bottom", "always_visible": True},
                ),
            ], width=4),
            dbc.Col([
                html.Label("Modulation", style={'color': TEXT_COLOR, 'fontWeight': 'bold'}),
                dcc.Dropdown(
                    id='mod-dropdown',
                    options=[
                        {'label': 'QPSK', 'value': 'QPSK'},
                        {'label': '16-QAM', 'value': '16QAM'},
                        {'label': '64-QAM', 'value': '64QAM'},
                    ],
                    value='QPSK',
                    style={'backgroundColor': '#313244', 'color': '#cdd6f4'},
                ),
            ], width=2),
            dbc.Col([
                html.Label("Channel", style={'color': TEXT_COLOR, 'fontWeight': 'bold'}),
                dcc.Dropdown(
                    id='channel-dropdown',
                    options=[
                        {'label': 'Flat (AWGN)', 'value': 'flat'},
                        {'label': 'Two-Tap', 'value': 'two_tap'},
                        {'label': 'TU-6 Urban', 'value': 'tu6'},
                    ],
                    value='flat',
                    style={'backgroundColor': '#313244', 'color': '#cdd6f4'},
                ),
            ], width=2),
            dbc.Col([
                html.Br(),
                dbc.Button("Run Simulation", id='run-btn', color='primary',
                           className='w-100'),
            ], width=2),
            dbc.Col([
                html.Div(id='status-display', children=[
                    html.Span("Ready", style={'color': ACCENT_3, 'fontWeight': 'bold'}),
                ]),
            ], width=2, className='d-flex align-items-center'),
        ]),
    ]),
], style={'backgroundColor': PAPER_BG, 'border': 'none', 'marginBottom': '10px'})

# --- Layout: 6-panel grid ---
app.layout = dbc.Container([
    html.H2("ATSC 3.0 OFDM + LDPC Decoder",
            style={'color': TEXT_COLOR, 'textAlign': 'center', 'marginTop': '10px',
                   'marginBottom': '5px', 'fontFamily': 'monospace'}),
    controls,
    dbc.Row([
        dbc.Col(dcc.Graph(id='constellation-before', style={'height': '350px'}), width=6),
        dbc.Col(dcc.Graph(id='constellation-after', style={'height': '350px'}), width=6),
    ]),
    dbc.Row([
        dbc.Col(dcc.Graph(id='psd-plot', style={'height': '350px'}), width=6),
        dbc.Col(dcc.Graph(id='channel-plot', style={'height': '350px'}), width=6),
    ]),
    dbc.Row([
        dbc.Col(dcc.Graph(id='ber-plot', style={'height': '350px'}), width=6),
        dbc.Col(dcc.Graph(id='convergence-plot', style={'height': '350px'}), width=6),
    ]),
    # Store simulation result
    dcc.Store(id='sim-store', data={'ready': True}),
], fluid=True, style={'backgroundColor': '#11111b', 'minHeight': '100vh'})


# ---------------------------------------------------------------------------
# Callbacks
# ---------------------------------------------------------------------------
@app.callback(
    [Output('constellation-before', 'figure'),
     Output('constellation-after', 'figure'),
     Output('psd-plot', 'figure'),
     Output('channel-plot', 'figure'),
     Output('ber-plot', 'figure'),
     Output('convergence-plot', 'figure'),
     Output('status-display', 'children')],
    [Input('run-btn', 'n_clicks')],
    [State('snr-slider', 'value'),
     State('mod-dropdown', 'value'),
     State('channel-dropdown', 'value')],
    prevent_initial_call=False,
)
def update_all(n_clicks, snr_db, modulation, channel_model):
    """Run simulation and update all plots."""
    if n_clicks is None:
        # Initial load — use pre-computed result
        result = INITIAL_RESULT
    else:
        result = run_ofdm_chain(
            snr_db=float(snr_db),
            modulation=modulation,
            channel_model=channel_model,
            seed=42
        )

    mod = result.modulation
    ref_points = CONSTELLATIONS.get(mod)
    params = OfdmParams(modulation=mod)

    # Build figures
    fig_before = make_constellation(
        result.raw_constellation, "Constellation (Before Equalization)", ref_points)
    fig_after = make_constellation(
        result.eq_constellation, "Constellation (After Equalization)", ref_points)
    fig_psd = make_psd(result.rx_signal, params.sample_rate)
    fig_channel = make_channel_response(
        result.true_channel_freq, result.estimated_channel, params.sample_rate)
    fig_ber = make_ber_waterfall(BER_DATA)
    fig_conv = make_convergence(result.iteration_data, 324)

    # Status
    if result.ldpc_converged:
        status = html.Span([
            html.Span("CONVERGED ", style={'color': ACCENT_3, 'fontWeight': 'bold'}),
            f"({result.ldpc_iterations} iters, BER={result.ber_coded:.2e})"
        ], style={'color': TEXT_COLOR})
    else:
        status = html.Span([
            html.Span("NOT CONVERGED ", style={'color': '#f38ba8', 'fontWeight': 'bold'}),
            f"({result.ldpc_iterations} iters, BER={result.ber_coded:.2e})"
        ], style={'color': TEXT_COLOR})

    return fig_before, fig_after, fig_psd, fig_channel, fig_ber, fig_conv, status


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    import webbrowser
    import threading

    port = 8050
    url = f"http://127.0.0.1:{port}"
    print(f"Dashboard launching at {url}")
    print("Press Ctrl+C to stop.\n")

    # Open browser after short delay
    threading.Timer(1.5, lambda: webbrowser.open(url)).start()

    app.run(debug=False, host='127.0.0.1', port=port)

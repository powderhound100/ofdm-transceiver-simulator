"""OFDM demodulator: CP removal, FFT, channel estimation, equalization."""
from __future__ import annotations
import numpy as np
from .params import OfdmParams
from .modulator import PILOT_VALUE


def ofdm_demodulate(rx_signal: np.ndarray, params: OfdmParams,
                    n_ofdm_symbols: int
                    ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """OFDM demodulation with pilot-based channel estimation.

    Args:
        rx_signal: Complex received time-domain samples
        params: OFDM parameters
        n_ofdm_symbols: Number of OFDM symbols to demodulate

    Returns:
        (raw_symbols, equalized_symbols, channel_estimate)
        - raw_symbols: complex data symbols before equalization (for constellation plot)
        - equalized_symbols: complex data symbols after equalization
        - channel_estimate: estimated H(f) across all subcarriers per OFDM symbol
    """
    data_idx = params.data_indices()
    pilot_idx = params.pilot_indices()
    symbol_len = params.fft_size + params.cp_length

    all_raw = []
    all_eq = []
    all_h_est = []

    for sym_i in range(n_ofdm_symbols):
        start = sym_i * symbol_len
        end = start + symbol_len
        if end > len(rx_signal):
            break

        # Remove cyclic prefix
        time_domain = rx_signal[start + params.cp_length:end]

        # FFT
        freq_domain = np.fft.fft(time_domain, params.fft_size)

        # Extract pilots and estimate channel at pilot positions
        rx_pilots = freq_domain[pilot_idx]
        h_at_pilots = rx_pilots / PILOT_VALUE  # LS estimation

        # Interpolate channel estimate to all subcarriers
        all_used_idx = np.sort(np.concatenate([data_idx, pilot_idx]))
        h_est_all = np.interp(
            all_used_idx.astype(float),
            pilot_idx.astype(float),
            np.abs(h_at_pilots)
        ) * np.exp(1j * np.interp(
            all_used_idx.astype(float),
            pilot_idx.astype(float),
            np.angle(h_at_pilots)
        ))

        # Build full FFT-sized channel estimate for visualization
        h_full = np.zeros(params.fft_size, dtype=np.complex64)
        h_full[all_used_idx] = h_est_all.astype(np.complex64)
        all_h_est.append(h_full)

        # Map back to data-only indices
        data_in_used = np.array([np.searchsorted(all_used_idx, d) for d in data_idx])
        h_at_data = h_est_all[data_in_used]

        # Extract raw data symbols (before equalization)
        raw_data = freq_domain[data_idx]
        all_raw.append(raw_data)

        # Zero-forcing equalization
        h_safe = np.where(np.abs(h_at_data) > 1e-6, h_at_data, 1e-6)
        eq_data = raw_data / h_safe
        all_eq.append(eq_data)

    raw_symbols = np.concatenate(all_raw).astype(np.complex64)
    eq_symbols = np.concatenate(all_eq).astype(np.complex64)
    # Average channel estimate across OFDM symbols
    h_est_avg = np.mean(all_h_est, axis=0).astype(np.complex64) if all_h_est else np.ones(params.fft_size, dtype=np.complex64)

    return raw_symbols, eq_symbols, h_est_avg

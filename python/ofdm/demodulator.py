"""OFDM demodulator: CP removal, FFT, channel estimation, equalization.

Supports three channel estimators and two equalizers:
  Estimators: LS, LS_improved, LMMSE
  Equalizers: ZF, MMSE
"""
from __future__ import annotations
import numpy as np
from .params import OfdmParams
from .modulator import PILOT_VALUE


# ---------------------------------------------------------------------------
# Channel estimators
# ---------------------------------------------------------------------------

def _estimate_ls(rx_pilots: np.ndarray, pilot_idx: np.ndarray,
                 all_used_idx: np.ndarray) -> np.ndarray:
    """Least-Squares estimation: interpolate magnitude and phase separately.

    This is the original estimator — it interpolates |H| and angle(H)
    independently, which can introduce artefacts when the phase wraps.
    """
    h_at_pilots = rx_pilots / PILOT_VALUE
    h_mag = np.interp(all_used_idx.astype(float),
                      pilot_idx.astype(float),
                      np.abs(h_at_pilots))
    h_phase = np.interp(all_used_idx.astype(float),
                        pilot_idx.astype(float),
                        np.angle(h_at_pilots))
    return h_mag * np.exp(1j * h_phase)


def _estimate_ls_improved(rx_pilots: np.ndarray, pilot_idx: np.ndarray,
                          all_used_idx: np.ndarray) -> np.ndarray:
    """LS estimation with real/imag interpolation (avoids phase-wrapping)."""
    h_at_pilots = rx_pilots / PILOT_VALUE
    h_real = np.interp(all_used_idx.astype(float),
                       pilot_idx.astype(float),
                       h_at_pilots.real)
    h_imag = np.interp(all_used_idx.astype(float),
                       pilot_idx.astype(float),
                       h_at_pilots.imag)
    return h_real + 1j * h_imag


def _estimate_lmmse(rx_pilots: np.ndarray, pilot_idx: np.ndarray,
                    all_used_idx: np.ndarray, fft_size: int,
                    noise_var: float) -> np.ndarray:
    """DFT-based Tikhonov-regularised LMMSE channel estimation.

    1. LS estimate at pilots
    2. IDFT to time domain -> truncate to significant taps -> DFT back
    3. Wiener-like smoothing: H_lmmse = H_dft * |H_dft|^2 / (|H_dft|^2 + beta)
       where beta = noise_var acts as a regularisation parameter.
    """
    h_at_pilots = rx_pilots / PILOT_VALUE

    # Step 1: interpolate LS to all used subcarriers (real/imag)
    h_real = np.interp(all_used_idx.astype(float),
                       pilot_idx.astype(float),
                       h_at_pilots.real)
    h_imag = np.interp(all_used_idx.astype(float),
                       pilot_idx.astype(float),
                       h_at_pilots.imag)
    h_ls = h_real + 1j * h_imag

    # Step 2: build full-band LS, go to time domain
    h_full = np.zeros(fft_size, dtype=np.complex128)
    h_full[all_used_idx] = h_ls
    h_time = np.fft.ifft(h_full)

    # Keep only first L taps (significant channel length)
    L = max(fft_size // 4, 16)
    h_time_trunc = np.zeros_like(h_time)
    h_time_trunc[:L] = h_time[:L]

    # Step 3: back to frequency domain and Wiener smoothing
    h_dft = np.fft.fft(h_time_trunc)
    power = np.abs(h_dft) ** 2
    beta = max(noise_var, 1e-10)
    h_lmmse_full = h_dft * power / (power + beta)

    return h_lmmse_full[all_used_idx]


# ---------------------------------------------------------------------------
# Main demodulation entry point
# ---------------------------------------------------------------------------

def ofdm_demodulate(rx_signal: np.ndarray, params: OfdmParams,
                    n_ofdm_symbols: int,
                    estimator: str = "LS",
                    equalizer: str = "ZF",
                    noise_var: float = 1e-3,
                    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    """OFDM demodulation with pilot-based channel estimation.

    Args:
        rx_signal: Complex received time-domain samples
        params: OFDM parameters
        n_ofdm_symbols: Number of OFDM symbols to demodulate
        estimator: "LS", "LS_improved", or "LMMSE"
        equalizer: "ZF" or "MMSE"
        noise_var: Noise variance estimate (used by LMMSE and MMSE)

    Returns:
        (raw_symbols, equalized_symbols, channel_estimate, effective_noise_var)
        - raw_symbols: complex data symbols before equalization
        - equalized_symbols: complex data symbols after equalization
        - channel_estimate: estimated H(f) across all subcarriers per OFDM symbol
        - effective_noise_var: per-subcarrier effective noise variance after equalization
    """
    data_idx = params.data_indices()
    pilot_idx = params.pilot_indices()
    symbol_len = params.fft_size + params.cp_length

    all_raw = []
    all_eq = []
    all_h_est = []
    all_eff_noise = []

    for sym_i in range(n_ofdm_symbols):
        start = sym_i * symbol_len
        end = start + symbol_len
        if end > len(rx_signal):
            break

        # Remove cyclic prefix
        time_domain = rx_signal[start + params.cp_length:end]

        # FFT
        freq_domain = np.fft.fft(time_domain, params.fft_size)

        # Extract pilots
        rx_pilots = freq_domain[pilot_idx]

        # All used subcarrier indices
        all_used_idx = np.sort(np.concatenate([data_idx, pilot_idx]))

        # --- Channel estimation ---
        if estimator == "LS":
            h_est_all = _estimate_ls(rx_pilots, pilot_idx, all_used_idx)
        elif estimator == "LS_improved":
            h_est_all = _estimate_ls_improved(rx_pilots, pilot_idx, all_used_idx)
        elif estimator == "LMMSE":
            h_est_all = _estimate_lmmse(rx_pilots, pilot_idx, all_used_idx,
                                        params.fft_size, noise_var)
        else:
            raise ValueError(f"Unknown estimator: {estimator}")

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

        # --- Equalization ---
        if equalizer == "ZF":
            h_safe = np.where(np.abs(h_at_data) > 1e-6, h_at_data, 1e-6)
            eq_data = raw_data / h_safe
            # Effective noise variance after ZF: sigma^2 / |H|^2
            eff_nv = noise_var / (np.abs(h_safe) ** 2)
        elif equalizer == "MMSE":
            h_conj = np.conj(h_at_data)
            denom = np.abs(h_at_data) ** 2 + noise_var
            denom = np.where(denom > 1e-10, denom, 1e-10)
            eq_data = raw_data * h_conj / denom
            # Effective noise variance after MMSE: sigma^2 / (|H|^2 + sigma^2)
            eff_nv = noise_var / denom
        else:
            raise ValueError(f"Unknown equalizer: {equalizer}")

        all_eq.append(eq_data)
        all_eff_noise.append(eff_nv)

    raw_symbols = np.concatenate(all_raw).astype(np.complex64)
    eq_symbols = np.concatenate(all_eq).astype(np.complex64)
    # Average channel estimate across OFDM symbols
    h_est_avg = (np.mean(all_h_est, axis=0).astype(np.complex64)
                 if all_h_est
                 else np.ones(params.fft_size, dtype=np.complex64))
    # Concatenate per-subcarrier effective noise variances
    eff_noise_all = np.concatenate(all_eff_noise).astype(np.float64) if all_eff_noise else np.full(1, noise_var)

    return raw_symbols, eq_symbols, h_est_avg, eff_noise_all

"""OFDM timing and frequency synchronization.

Implements Schmidl-Cox symbol timing and CP-based CFO estimation.
"""
from __future__ import annotations
import numpy as np


def schmidl_cox_timing(rx_signal: np.ndarray, fft_size: int,
                       cp_length: int) -> int:
    """Schmidl-Cox symbol timing synchronization using CP correlation.

    Correlate received signal with its CP-delayed copy:
        P[n] = sum_{k=0}^{CP-1} r[n+k] * conj(r[n+k+N])
        R[n] = sum_{k=0}^{CP-1} |r[n+k+N]|^2
        M[n] = |P[n]|^2 / R[n]^2

    Peak of M[n] = start of OFDM symbol (CP start).

    Args:
        rx_signal: Complex received samples
        fft_size: FFT size N
        cp_length: Cyclic prefix length

    Returns:
        Estimated symbol start index
    """
    N = fft_size
    L = cp_length
    sig_len = len(rx_signal)

    if sig_len < N + L:
        return 0

    # Sliding correlation
    search_range = min(sig_len - N - L, 2 * (N + L))
    metric = np.zeros(search_range)

    for n in range(search_range):
        P = np.sum(rx_signal[n:n+L] * np.conj(rx_signal[n+N:n+N+L]))
        R = np.sum(np.abs(rx_signal[n+N:n+N+L]) ** 2)
        if R > 1e-10:
            metric[n] = np.abs(P) ** 2 / (R ** 2)

    return int(np.argmax(metric))


def estimate_cfo_cp(rx_signal: np.ndarray, symbol_start: int,
                    fft_size: int, cp_length: int) -> float:
    """Estimate fractional CFO from cyclic prefix correlation.

    CFO = angle(P[n_peak]) / (2 * pi * N)

    where P is the CP correlation at the detected symbol start.

    Args:
        rx_signal: Complex received samples
        symbol_start: Detected symbol start (from schmidl_cox_timing)
        fft_size: FFT size N
        cp_length: CP length

    Returns:
        Fractional CFO estimate (normalized to subcarrier spacing)
    """
    N = fft_size
    L = cp_length
    n = symbol_start

    if n + N + L > len(rx_signal):
        return 0.0

    # CP correlation at detected symbol start
    P = np.sum(rx_signal[n:n+L] * np.conj(rx_signal[n+N:n+N+L]))

    # CFO estimate
    cfo = np.angle(P) / (2 * np.pi * N)
    return float(cfo)


def correct_cfo(rx_signal: np.ndarray, cfo: float,
                sample_rate: float = 1.0) -> np.ndarray:
    """Apply CFO correction to received signal.

    r_corrected[n] = r[n] * exp(-j * 2 * pi * cfo * n)

    Args:
        rx_signal: Complex received samples
        cfo: Estimated CFO (normalized to subcarrier spacing)
        sample_rate: Not used (CFO is already normalized)

    Returns:
        CFO-corrected signal
    """
    n = np.arange(len(rx_signal))
    correction = np.exp(-1j * 2 * np.pi * cfo * n)
    return (rx_signal * correction).astype(np.complex64)


def estimate_fine_cfo_pilots(h_pilot_curr: np.ndarray,
                             h_pilot_prev: np.ndarray,
                             symbol_duration: float) -> float:
    """Estimate residual CFO from pilot phase rotation across symbols.

    delta_f = mean(angle(H_pilot[sym+1] / H_pilot[sym])) / (2*pi*T_sym)

    Args:
        h_pilot_curr: Channel estimates at pilots for current symbol
        h_pilot_prev: Channel estimates at pilots for previous symbol
        symbol_duration: OFDM symbol duration in seconds

    Returns:
        Fine frequency offset estimate in Hz
    """
    if len(h_pilot_curr) == 0 or len(h_pilot_prev) == 0:
        return 0.0

    # Phase rotation per symbol
    ratio = h_pilot_curr / np.where(np.abs(h_pilot_prev) > 1e-10,
                                     h_pilot_prev, 1e-10)
    phase_diff = np.mean(np.angle(ratio))

    # Convert to frequency
    delta_f = phase_diff / (2 * np.pi * symbol_duration)
    return float(delta_f)

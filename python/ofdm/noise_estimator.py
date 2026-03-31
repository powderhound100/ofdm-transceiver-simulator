"""Noise variance estimation from pilot subcarriers."""
from __future__ import annotations
import numpy as np
from .modulator import PILOT_VALUE


def estimate_noise_variance(rx_pilots: np.ndarray,
                            h_est_at_pilots: np.ndarray) -> float:
    """Estimate noise variance from pilot subcarriers.

    Algorithm:
        noise_at_pilot[k] = |RX_pilot[k] - TX_PILOT * H_est[k]|^2
        sigma^2 = mean(noise_at_pilot)

    Args:
        rx_pilots: Received pilot values (complex)
        h_est_at_pilots: Channel estimates at pilot positions (complex)

    Returns:
        Estimated noise variance (float)
    """
    # Expected received pilot = TX_PILOT * H_est
    expected = PILOT_VALUE * h_est_at_pilots
    # Noise = difference between actual and expected
    noise = rx_pilots - expected
    # Variance = mean |noise|^2
    noise_var = float(np.mean(np.abs(noise) ** 2))
    return max(noise_var, 1e-10)  # Guard against zero


def estimate_noise_variance_multi_symbol(
    rx_pilots_list: list[np.ndarray],
    h_est_at_pilots_list: list[np.ndarray],
    alpha: float = 0.5
) -> float:
    """Estimate noise variance with exponential moving average across symbols.

    Args:
        rx_pilots_list: List of received pilot arrays (one per OFDM symbol)
        h_est_at_pilots_list: List of channel estimates at pilots
        alpha: EMA smoothing factor (0 = no smoothing, 1 = full weight on new)

    Returns:
        Smoothed noise variance estimate
    """
    if not rx_pilots_list:
        return 1e-10

    sigma2 = estimate_noise_variance(rx_pilots_list[0], h_est_at_pilots_list[0])

    for i in range(1, len(rx_pilots_list)):
        new_est = estimate_noise_variance(rx_pilots_list[i], h_est_at_pilots_list[i])
        sigma2 = (1 - alpha) * sigma2 + alpha * new_est

    return sigma2

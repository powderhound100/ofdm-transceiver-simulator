"""Channel models: multipath fading + AWGN for complex baseband signals."""
from __future__ import annotations
import numpy as np

# Standard channel models (delay in samples, power in dB)
CHANNEL_MODELS = {
    "flat": {
        "delays": [0],
        "powers_db": [0.0],
        "description": "Flat fading (single tap, AWGN-like)",
    },
    "two_tap": {
        "delays": [0, 5],
        "powers_db": [0.0, -3.0],
        "description": "Two-tap: main path + 5-sample delayed reflection at -3dB",
    },
    "tu6": {
        "delays": [0, 1, 3, 5, 8, 12],
        "powers_db": [-3.0, 0.0, -2.0, -6.0, -8.0, -10.0],
        "description": "Typical Urban 6-tap (TU-6), standard DTV test channel",
    },
    "cost207_ra": {
        "delays": [0, 1, 2, 3],
        "powers_db": [0.0, -2.0, -10.0, -20.0],
        "description": "COST 207 Rural Area — 4 taps, short delay spread",
    },
    "cost207_ht": {
        "delays": [0, 2, 4, 7, 11, 17],
        "powers_db": [0.0, -2.0, -4.0, -7.0, -6.0, -12.0],
        "description": "COST 207 Hilly Terrain — 6 taps, moderate delay spread",
    },
    "brazil_a": {
        "delays": [0, 3, 13],
        "powers_db": [0.0, -15.0, -20.0],
        "description": "Brazil channel A — 3 taps, indoor reception",
    },
    "brazil_b": {
        "delays": [0, 1, 3, 11, 57],
        "powers_db": [0.0, -12.0, -4.0, -7.0, -15.0],
        "description": "Brazil channel B — 5 taps, outdoor pedestrian",
    },
    "brazil_c": {
        "delays": [0, 1, 2, 5, 11, 17],
        "powers_db": [0.0, -5.0, -2.0, -6.0, -8.0, -10.0],
        "description": "Brazil channel C — 6 taps, vehicular urban",
    },
    "brazil_d": {
        "delays": [0, 3, 5, 13, 50, 120],
        "powers_db": [0.0, -10.0, -3.0, -4.0, -7.0, -15.0],
        "description": "Brazil channel D — 6 taps, mountainous / SFN",
    },
    "brazil_e": {
        "delays": [0, 1, 3, 10, 25, 138],
        "powers_db": [0.0, -5.0, -2.0, -6.0, -8.0, -10.0],
        "description": "Brazil channel E — 6 taps, SFN equal-power echoes",
    },
}


def make_channel_taps(model_name: str, rng: np.random.Generator | None = None
                      ) -> np.ndarray:
    """Create complex channel impulse response from a named model.

    Returns complex64 array of channel taps.
    """
    model = CHANNEL_MODELS[model_name]
    delays = model["delays"]
    powers_db = model["powers_db"]

    max_delay = max(delays)
    h = np.zeros(max_delay + 1, dtype=np.complex128)

    for d, p_db in zip(delays, powers_db):
        amplitude = 10 ** (p_db / 20.0)
        if rng is not None:
            # Random phase (Rayleigh-like)
            phase = rng.uniform(0, 2 * np.pi)
            h[d] = amplitude * np.exp(1j * phase)
        else:
            # Deterministic (all real)
            h[d] = amplitude

    # Normalize to unit energy
    h /= np.sqrt(np.sum(np.abs(h) ** 2))
    return h.astype(np.complex64)


def apply_multipath(signal: np.ndarray, channel_taps: np.ndarray) -> np.ndarray:
    """Apply multipath channel to complex baseband signal via convolution."""
    return np.convolve(signal, channel_taps, mode='same').astype(np.complex64)


def apply_awgn(signal: np.ndarray, snr_db: float, rng: np.random.Generator
               ) -> np.ndarray:
    """Add AWGN noise to complex signal.

    SNR is defined as signal power / noise power.
    """
    if snr_db == float('inf'):
        return signal.copy()

    sig_power = np.mean(np.abs(signal.astype(np.complex128)) ** 2)
    snr_linear = 10 ** (snr_db / 10.0)
    noise_power = sig_power / snr_linear

    noise = np.sqrt(noise_power / 2) * (
        rng.standard_normal(len(signal)) + 1j * rng.standard_normal(len(signal))
    )
    return (signal + noise).astype(np.complex64)


def channel_frequency_response(channel_taps: np.ndarray, fft_size: int
                               ) -> np.ndarray:
    """Compute channel frequency response H(f) for visualization."""
    h_padded = np.zeros(fft_size, dtype=np.complex128)
    h_padded[:len(channel_taps)] = channel_taps
    return np.fft.fft(h_padded).astype(np.complex64)

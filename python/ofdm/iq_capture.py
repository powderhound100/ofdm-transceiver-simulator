"""IQ data sources: simulated, file-based, and (optional) live SDR."""
from __future__ import annotations
import os
import numpy as np


def load_iq_file(filepath: str) -> np.ndarray:
    """Load IQ samples from various file formats.

    Supported formats:
      .raw, .bin — interleaved uint8 I/Q (RTL-SDR: unsigned, offset 128)
      .cf32, .fc32 — interleaved float32 I/Q
      .cs16, .sc16 — interleaved int16 I/Q

    Returns complex64 array normalized to approximately unit amplitude.
    """
    ext = os.path.splitext(filepath)[1].lower()

    if ext in ('.raw', '.bin'):
        raw = np.fromfile(filepath, dtype=np.uint8)
        # RTL-SDR format: unsigned 8-bit, 128 = zero
        iq = (raw.astype(np.float32) - 128.0) / 128.0
        return (iq[0::2] + 1j * iq[1::2]).astype(np.complex64)

    elif ext in ('.cf32', '.fc32'):
        raw = np.fromfile(filepath, dtype=np.float32)
        return (raw[0::2] + 1j * raw[1::2]).astype(np.complex64)

    elif ext in ('.cs16', '.sc16'):
        raw = np.fromfile(filepath, dtype=np.int16)
        iq = raw.astype(np.float32) / 32768.0
        return (iq[0::2] + 1j * iq[1::2]).astype(np.complex64)

    else:
        raise ValueError(f"Unknown IQ file format: {ext}")


def generate_test_iq(num_samples: int = 4096, freq_offset_hz: float = 0.0,
                     sample_rate: float = 6e6,
                     rng: np.random.Generator | None = None) -> np.ndarray:
    """Generate synthetic complex IQ samples for testing.

    Produces a noisy multi-tone signal resembling an OFDM spectrum.
    """
    if rng is None:
        rng = np.random.default_rng(42)

    t = np.arange(num_samples) / sample_rate
    signal = np.zeros(num_samples, dtype=np.complex128)

    # Multiple tones to simulate OFDM subcarriers
    n_tones = 48
    freqs = np.linspace(-sample_rate / 4, sample_rate / 4, n_tones)
    for f in freqs:
        phase = rng.uniform(0, 2 * np.pi)
        signal += np.exp(1j * (2 * np.pi * f * t + phase))

    signal /= np.sqrt(n_tones)

    # Apply frequency offset
    if freq_offset_hz != 0:
        signal *= np.exp(1j * 2 * np.pi * freq_offset_hz * t)

    # Add noise
    noise = 0.1 * (rng.standard_normal(num_samples) + 1j * rng.standard_normal(num_samples))
    signal += noise

    return signal.astype(np.complex64)

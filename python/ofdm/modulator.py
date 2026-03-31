"""OFDM modulator: QAM mapping, IFFT, cyclic prefix insertion."""
from __future__ import annotations
import numpy as np
from .params import OfdmParams


def _build_rect_qam(n_i: int, n_q: int) -> np.ndarray:
    """Build rectangular QAM constellation with unit average energy."""
    levels_i = np.arange(-(n_i - 1), n_i, 2, dtype=np.float64)
    levels_q = np.arange(-(n_q - 1), n_q, 2, dtype=np.float64)
    grid = np.array([i + 1j * q for q in levels_q for i in levels_i])
    e_avg = np.mean(np.abs(grid) ** 2)
    return (grid / np.sqrt(e_avg)).astype(np.complex64)


_QPSK    = _build_rect_qam(2, 2)
_16QAM   = _build_rect_qam(4, 4)
_64QAM   = _build_rect_qam(8, 8)
_256QAM  = _build_rect_qam(16, 16)
_512QAM  = _build_rect_qam(32, 16)
_1024QAM = _build_rect_qam(32, 32)
_2048QAM = _build_rect_qam(64, 32)

CONSTELLATIONS = {
    "QPSK": _QPSK, "16QAM": _16QAM, "64QAM": _64QAM,
    "256QAM": _256QAM, "512QAM": _512QAM, "1024QAM": _1024QAM, "2048QAM": _2048QAM,
}
BPS = {"QPSK": 2, "16QAM": 4, "64QAM": 6, "256QAM": 8, "512QAM": 9, "1024QAM": 10, "2048QAM": 11}

# Pilot value: known BPSK symbol (+1)
PILOT_VALUE = 1.0 + 0.0j


def qam_map(bits: np.ndarray, modulation: str = "QPSK") -> np.ndarray:
    """Map coded bits to QAM symbols.

    Args:
        bits: uint8 array of 0/1 values
        modulation: "QPSK", "16QAM", "64QAM", "256QAM", "512QAM", "1024QAM", or "2048QAM"

    Returns:
        Complex64 array of QAM symbols
    """
    bps = BPS[modulation]
    constellation = CONSTELLATIONS[modulation]

    # Pad bits to multiple of bps
    n_bits = len(bits)
    pad_len = (bps - n_bits % bps) % bps
    if pad_len > 0:
        bits = np.concatenate([bits, np.zeros(pad_len, dtype=np.uint8)])

    # Convert bit groups to symbol indices
    n_symbols = len(bits) // bps
    indices = np.zeros(n_symbols, dtype=int)
    for i in range(bps):
        indices += bits[i::bps].astype(int) << (bps - 1 - i)

    return constellation[indices].astype(np.complex64)


def qam_demap_soft(symbols: np.ndarray, noise_var: float,
                   modulation: str = "QPSK") -> np.ndarray:
    """Soft QAM demapping to LLR values (max-log-MAP approximation).

    Returns float64 LLR array (positive = bit 0 more likely).
    """
    bps = BPS[modulation]

    if noise_var <= 0:
        noise_var = 1e-10

    # Vectorized max-log-MAP for all modulations
    constellation = CONSTELLATIONS[modulation]
    n_symbols = len(symbols)
    llr = np.empty(n_symbols * bps, dtype=np.float64)

    for k in range(bps):
        bit_mask = 1 << (bps - 1 - k)
        s0 = constellation[np.array([(i & bit_mask) == 0 for i in range(len(constellation))])]
        s1 = constellation[np.array([(i & bit_mask) != 0 for i in range(len(constellation))])]
        d0 = np.min(np.abs(symbols[:, None] - s0[None, :]) ** 2, axis=1)
        d1 = np.min(np.abs(symbols[:, None] - s1[None, :]) ** 2, axis=1)
        llr[k::bps] = (d1 - d0) / noise_var

    return llr


def ofdm_modulate(qam_symbols: np.ndarray, params: OfdmParams) -> np.ndarray:
    """OFDM modulation: map QAM symbols to time-domain IQ.

    Inserts pilots, performs IFFT, adds cyclic prefix.

    Returns complex64 time-domain IQ samples.
    """
    data_idx = params.data_indices()
    pilot_idx = params.pilot_indices()
    n_data = params.num_data_carriers
    n_ofdm = int(np.ceil(len(qam_symbols) / n_data))

    # Pad QAM symbols to fill complete OFDM symbols
    total_data = n_ofdm * n_data
    if len(qam_symbols) < total_data:
        qam_symbols = np.concatenate([
            qam_symbols,
            np.zeros(total_data - len(qam_symbols), dtype=np.complex64)
        ])

    tx_signal = []
    for sym_i in range(n_ofdm):
        # Build frequency-domain OFDM symbol
        freq_domain = np.zeros(params.fft_size, dtype=np.complex64)

        # Insert data
        data_chunk = qam_symbols[sym_i * n_data:(sym_i + 1) * n_data]
        freq_domain[data_idx] = data_chunk

        # Insert pilots
        freq_domain[pilot_idx] = PILOT_VALUE

        # IFFT -> time domain
        time_domain = np.fft.ifft(freq_domain).astype(np.complex64)

        # Add cyclic prefix
        cp = time_domain[-params.cp_length:]
        ofdm_symbol = np.concatenate([cp, time_domain])
        tx_signal.append(ofdm_symbol)

    return np.concatenate(tx_signal)

"""OFDM modulator: QAM mapping, IFFT, cyclic prefix insertion."""
from __future__ import annotations
import numpy as np
from .params import OfdmParams


# QPSK constellation: b0 maps to I (real), b1 maps to Q (imag)
# Index = b0*2 + b1: b0=0 -> I>0, b0=1 -> I<0, b1=0 -> Q>0, b1=1 -> Q<0
_QPSK = np.array([1+1j, 1-1j, -1+1j, -1-1j]) / np.sqrt(2)

# 16QAM constellation: Gray-coded
_16QAM_LEVELS = np.array([-3, -1, 1, 3]) / np.sqrt(10)
_16QAM = np.array([i + 1j*q for q in _16QAM_LEVELS for i in _16QAM_LEVELS])

# 64QAM constellation
_64QAM_LEVELS = np.array([-7, -5, -3, -1, 1, 3, 5, 7]) / np.sqrt(42)
_64QAM = np.array([i + 1j*q for q in _64QAM_LEVELS for i in _64QAM_LEVELS])

CONSTELLATIONS = {
    "QPSK": _QPSK,
    "16QAM": _16QAM,
    "64QAM": _64QAM,
}

# Pilot value: known BPSK symbol (+1)
PILOT_VALUE = 1.0 + 0.0j


def qam_map(bits: np.ndarray, modulation: str = "QPSK") -> np.ndarray:
    """Map coded bits to QAM symbols.

    Args:
        bits: uint8 array of 0/1 values
        modulation: "QPSK", "16QAM", or "64QAM"

    Returns:
        Complex64 array of QAM symbols
    """
    bps = {"QPSK": 2, "16QAM": 4, "64QAM": 6}[modulation]
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
    """Soft QAM demapping to LLR values.

    For QPSK, this reduces to simple real/imag scaling.
    For higher-order QAM, uses max-log-MAP approximation.

    Returns float64 LLR array (positive = bit 0 more likely).
    """
    bps = {"QPSK": 2, "16QAM": 4, "64QAM": 6}[modulation]

    if noise_var <= 0:
        noise_var = 1e-10

    if modulation == "QPSK":
        # QPSK decomposes to two independent BPSK channels
        scale = 2.0 * np.sqrt(2) / noise_var
        llr_i = scale * symbols.real.astype(np.float64)
        llr_q = scale * symbols.imag.astype(np.float64)
        # Interleave: [I0, Q0, I1, Q1, ...]
        llr = np.empty(len(symbols) * 2, dtype=np.float64)
        llr[0::2] = llr_i
        llr[1::2] = llr_q
        return llr

    # Max-log-MAP for higher-order QAM
    constellation = CONSTELLATIONS[modulation]
    n_symbols = len(symbols)
    llr = np.empty(n_symbols * bps, dtype=np.float64)

    for k in range(bps):
        bit_mask = 1 << (bps - 1 - k)
        s0 = constellation[np.array([(i & bit_mask) == 0 for i in range(len(constellation))])]
        s1 = constellation[np.array([(i & bit_mask) != 0 for i in range(len(constellation))])]

        for sym_idx in range(n_symbols):
            y = symbols[sym_idx]
            d0 = np.min(np.abs(y - s0) ** 2)
            d1 = np.min(np.abs(y - s1) ** 2)
            llr[sym_idx * bps + k] = (d1 - d0) / noise_var

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

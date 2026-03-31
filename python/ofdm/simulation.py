"""End-to-end OFDM simulation chain: bits -> OFDM Tx -> channel -> OFDM Rx -> LDPC."""
from __future__ import annotations
from dataclasses import dataclass, field
import sys
import os
import numpy as np

# Add parent dir to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from ldpc_code import make_wifi_code, QcLdpcCode
from encoder import LdpcEncoder
from decoder import MinSumDecoder

from .params import OfdmParams, DEFAULT_PARAMS
from .modulator import qam_map, qam_demap_soft, ofdm_modulate
from .channel_model import make_channel_taps, apply_multipath, apply_awgn, channel_frequency_response
from .demodulator import ofdm_demodulate


@dataclass
class OfdmSimResult:
    """Complete result from one OFDM simulation run."""
    # Config
    snr_db: float
    modulation: str
    channel_model: str
    estimator: str = "LS"
    equalizer: str = "ZF"

    # Transmitter
    info_bits: np.ndarray = field(default=None)
    coded_bits: np.ndarray = field(default=None)
    qam_symbols: np.ndarray = field(default=None)
    tx_signal: np.ndarray = field(default=None)             # complex time-domain IQ

    # Channel
    rx_signal: np.ndarray = field(default=None)             # complex IQ after channel
    channel_taps: np.ndarray = field(default=None)          # true channel impulse response
    true_channel_freq: np.ndarray = field(default=None)     # H(f) ground truth

    # Receiver
    raw_constellation: np.ndarray = field(default=None)     # before equalization
    eq_constellation: np.ndarray = field(default=None)      # after equalization
    estimated_channel: np.ndarray = field(default=None)     # H_est(f) from pilots
    soft_llr: np.ndarray = field(default=None)

    # LDPC
    decoded_bits: np.ndarray = field(default=None)
    ldpc_iterations: int = 0
    ldpc_converged: bool = False
    iteration_data: list = field(default_factory=list)

    # Performance
    ber_uncoded: float = 0.0                # QAM hard decision BER
    ber_coded: float = 0.0                  # post-LDPC BER


def run_ofdm_chain(snr_db: float = 2.0,
                   modulation: str = "QPSK",
                   channel_model: str = "flat",
                   params: OfdmParams | None = None,
                   seed: int = 42,
                   estimator: str = "LS",
                   equalizer: str = "ZF") -> OfdmSimResult:
    """Run complete OFDM + LDPC chain.

    Args:
        snr_db: Channel SNR in dB
        modulation: QAM order ("QPSK", "16QAM", "64QAM", "256QAM", "512QAM", "1024QAM", "2048QAM")
        channel_model: Channel name ("flat", "two_tap", "tu6", etc.)
        params: OFDM parameters (uses defaults if None)
        seed: Random seed
        estimator: Channel estimator ("LS", "LS_improved", "LMMSE")
        equalizer: Equalizer type ("ZF", "MMSE")

    Returns:
        OfdmSimResult with all intermediate data for visualization
    """
    if params is None:
        params = OfdmParams(modulation=modulation)
    else:
        params.modulation = modulation

    rng = np.random.default_rng(seed)

    # --- LDPC setup ---
    code = make_wifi_code()
    enc = LdpcEncoder(code)
    dec = MinSumDecoder(code, alpha=0.75, max_iter=50)

    # --- Transmitter ---
    info_bits = rng.integers(0, 2, size=code.K, dtype=np.uint8)
    coded_bits = enc.encode(info_bits)
    qam_symbols = qam_map(coded_bits, modulation)
    tx_signal = ofdm_modulate(qam_symbols, params)

    # --- Channel ---
    channel_taps = make_channel_taps(channel_model, rng)
    rx_after_mp = apply_multipath(tx_signal, channel_taps)
    rx_signal = apply_awgn(rx_after_mp, snr_db, rng)
    true_h_freq = channel_frequency_response(channel_taps, params.fft_size)

    # --- Receiver ---
    n_ofdm = params.symbols_per_codeword(code.N)

    # Compute noise variance for estimation / equalization
    snr_linear = 10 ** (snr_db / 10.0) if snr_db != float('inf') else 1e10
    sig_power = np.mean(np.abs(tx_signal.astype(np.complex128)) ** 2)
    noise_var = float(sig_power / snr_linear) if snr_linear > 0 else 1e-10

    raw_const, eq_const, h_est, eff_noise = ofdm_demodulate(
        rx_signal, params, n_ofdm,
        estimator=estimator, equalizer=equalizer, noise_var=noise_var)

    # Soft demap equalized symbols -> LLR
    # Use mean effective noise variance from equalizer output
    demapping_noise = float(np.mean(eff_noise))
    n_coded_bits = code.N
    soft_llr = qam_demap_soft(eq_const[:len(qam_symbols)], demapping_noise, modulation)

    # Trim/pad LLR to match code length
    if len(soft_llr) > n_coded_bits:
        soft_llr = soft_llr[:n_coded_bits]
    elif len(soft_llr) < n_coded_bits:
        soft_llr = np.concatenate([soft_llr, np.zeros(n_coded_bits - len(soft_llr))])

    # --- LDPC decode ---
    result = dec.decode(soft_llr, capture_iterations=True)

    # --- Compute BER ---
    # Uncoded: hard decision on LLR
    hard_uncoded = (soft_llr[:code.K] < 0).astype(np.uint8)
    ber_uncoded = float(np.sum(hard_uncoded != info_bits) / code.K)

    decoded_info = result['decoded_bits'][:code.K]
    ber_coded = float(np.sum(decoded_info != info_bits) / code.K)

    return OfdmSimResult(
        snr_db=snr_db,
        modulation=modulation,
        channel_model=channel_model,
        estimator=estimator,
        equalizer=equalizer,
        info_bits=info_bits,
        coded_bits=coded_bits,
        qam_symbols=qam_symbols,
        tx_signal=tx_signal,
        rx_signal=rx_signal,
        channel_taps=channel_taps,
        true_channel_freq=true_h_freq,
        raw_constellation=raw_const,
        eq_constellation=eq_const,
        estimated_channel=h_est,
        soft_llr=soft_llr,
        decoded_bits=result['decoded_bits'],
        ldpc_iterations=result['num_iterations'],
        ldpc_converged=result['converged'],
        iteration_data=result['iteration_data'],
        ber_uncoded=ber_uncoded,
        ber_coded=ber_coded,
    )


if __name__ == "__main__":
    print("=== OFDM + LDPC End-to-End Test ===\n")
    for snr in [0.0, 2.0, 5.0, float('inf')]:
        r = run_ofdm_chain(snr_db=snr, channel_model="flat")
        status = "CONV" if r.ldpc_converged else "FAIL"
        print(f"SNR={snr:>5} dB | {status} iter={r.ldpc_iterations:>2} | "
              f"BER_uncoded={r.ber_uncoded:.4f} BER_coded={r.ber_coded:.4f}")

    print("\nMultipath (TU-6):")
    for snr in [5.0, 10.0, 15.0]:
        r = run_ofdm_chain(snr_db=snr, channel_model="tu6")
        status = "CONV" if r.ldpc_converged else "FAIL"
        print(f"SNR={snr:>5} dB | {status} iter={r.ldpc_iterations:>2} | "
              f"BER_uncoded={r.ber_uncoded:.4f} BER_coded={r.ber_coded:.4f}")

"""OFDM receiver chain test vector generator for FPGA verification.

Generates hex files for each processing stage of the OFDM receiver:
  TX IQ -> RX IQ -> CP removal -> FFT -> pilot/data extraction ->
  channel estimation -> equalization -> soft demap -> LDPC decode

Uses "quantize-then-propagate": after each stage, values are quantized
to FPGA bit widths before feeding to the next stage.

Fixed seed=42 for reproducibility. Output under test_vectors/ofdm/.
"""
from __future__ import annotations

import os
import sys
import numpy as np

# Ensure the python/ directory is on the path for ldpc_code, encoder, decoder
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ofdm.params import OfdmParams
from ofdm.modulator import qam_map, ofdm_modulate, qam_demap_soft, PILOT_VALUE, CONSTELLATIONS
from ofdm.demodulator import ofdm_demodulate
from ofdm.channel_model import make_channel_taps, apply_multipath, apply_awgn
from ldpc_code import make_wifi_code
from encoder import LdpcEncoder
from decoder import MinSumDecoder


# =============================================================================
# Quantization helpers
# =============================================================================

def quantize_q114(val_complex, bits=16):
    """Quantize complex value to Q1.14 fixed-point."""
    scale = 2**14
    re = int(np.clip(np.round(val_complex.real * scale), -(2**(bits-1)-1), 2**(bits-1)-1))
    im = int(np.clip(np.round(val_complex.imag * scale), -(2**(bits-1)-1), 2**(bits-1)-1))
    return re, im


def to_hex32(re_16, im_16):
    """Pack 16-bit I,Q into 32-bit hex: {Q[15:0], I[15:0]}."""
    re_u = re_16 & 0xFFFF
    im_u = im_16 & 0xFFFF
    return f"{(im_u << 16) | re_u:08x}"


def quantize_llr_6bit(llr_float):
    """Quantize LLR to 6-bit signed [-31, +31]."""
    val = int(np.clip(np.round(llr_float), -31, 31))
    if val < 0:
        val = 64 + val
    return f"{val:02x}"


def complex_array_to_hex(arr):
    """Convert complex array to list of 32-bit hex strings via Q1.14."""
    lines = []
    for v in arr:
        re, im = quantize_q114(v)
        lines.append(to_hex32(re, im))
    return lines


def q114_to_complex(re_int, im_int):
    """Convert Q1.14 integers back to complex float."""
    return (re_int / 2**14) + 1j * (im_int / 2**14)


def quantize_complex_array(arr):
    """Quantize complex array to Q1.14 and return the dequantized version."""
    out = np.empty_like(arr, dtype=np.complex128)
    for i, v in enumerate(arr):
        re, im = quantize_q114(v)
        out[i] = q114_to_complex(re, im)
    return out.astype(np.complex64)


# =============================================================================
# Scenario definitions
# =============================================================================

SCENARIOS = {
    "flat_noiseless": {"channel": "flat",    "snr_db": float('inf')},
    "flat_10dB":      {"channel": "flat",    "snr_db": 10.0},
    "flat_5dB":       {"channel": "flat",    "snr_db": 5.0},
    "two_tap_10dB":   {"channel": "two_tap", "snr_db": 10.0},
    "tu6_10dB":       {"channel": "tu6",     "snr_db": 10.0},
}


# =============================================================================
# Main generator
# =============================================================================

def generate_ofdm_vectors(output_dir: str):
    """Generate OFDM test vectors for all scenarios."""
    os.makedirs(output_dir, exist_ok=True)

    params = OfdmParams()  # FFT=64, CP=16, 48 data, 4 pilot, QPSK
    code = make_wifi_code()
    enc = LdpcEncoder(code)
    dec = MinSumDecoder(code, alpha=0.75, max_iter=50)

    data_idx = params.data_indices()
    pilot_idx = params.pilot_indices()
    n_data = params.num_data_carriers   # 48
    symbol_len = params.fft_size + params.cp_length  # 80

    print(f"OFDM params: FFT={params.fft_size}, CP={params.cp_length}, "
          f"data={n_data}, pilot={params.num_pilot_carriers}")
    print(f"Code: N={code.N}, K={code.K}, rate={code.rate:.3f}")
    print(f"Output: {output_dir}\n")

    for scn_name, scn_cfg in SCENARIOS.items():
        print(f"--- Scenario: {scn_name} ---")
        ch_name = scn_cfg["channel"]
        snr_db = scn_cfg["snr_db"]

        rng = np.random.default_rng(42)

        # -----------------------------------------------------------------
        # 1. Generate info bits and LDPC encode
        # -----------------------------------------------------------------
        info_bits = rng.integers(0, 2, size=code.K, dtype=np.uint8)
        coded_bits = enc.encode(info_bits)
        print(f"  Info bits: {code.K}, coded bits: {code.N}")

        # -----------------------------------------------------------------
        # 2. QAM map (QPSK) -> 324 symbols
        # -----------------------------------------------------------------
        qam_symbols = qam_map(coded_bits, "QPSK")
        n_qam = len(qam_symbols)
        print(f"  QAM symbols: {n_qam}")

        # -----------------------------------------------------------------
        # 3. OFDM modulate -> 7 symbols x 80 = 560 TX IQ samples
        # -----------------------------------------------------------------
        n_ofdm = params.symbols_per_codeword(code.N)
        tx_signal = ofdm_modulate(qam_symbols, params)
        print(f"  OFDM symbols: {n_ofdm}, TX samples: {len(tx_signal)}")

        # Quantize TX IQ
        tx_q = quantize_complex_array(tx_signal)

        # -----------------------------------------------------------------
        # 4. Apply channel
        # -----------------------------------------------------------------
        channel_taps = make_channel_taps(ch_name, rng=None)  # deterministic
        rx_after_mp = apply_multipath(tx_q, channel_taps)

        # -----------------------------------------------------------------
        # 5. Apply AWGN (use a separate RNG for noise to keep it reproducible)
        # -----------------------------------------------------------------
        rng_noise = np.random.default_rng(42)
        rx_signal = apply_awgn(rx_after_mp, snr_db, rng_noise)

        # Quantize RX IQ
        rx_q = quantize_complex_array(rx_signal)

        # -----------------------------------------------------------------
        # 6. OFDM demodulate — step by step with quantization at each stage
        # -----------------------------------------------------------------
        all_after_cp = []
        all_fft_out = []
        all_pilots = []
        all_data = []
        all_h_est = []
        all_eq_data = []

        for sym_i in range(n_ofdm):
            start = sym_i * symbol_len
            end = start + symbol_len
            if end > len(rx_q):
                break

            # CP removal
            after_cp = rx_q[start + params.cp_length:end]
            # Quantize after CP removal
            after_cp_q = quantize_complex_array(after_cp)
            all_after_cp.append(after_cp_q)

            # FFT
            fft_out = np.fft.fft(after_cp_q, params.fft_size)
            fft_out_q = quantize_complex_array(fft_out)
            all_fft_out.append(fft_out_q)

            # Extract pilots
            rx_pilots = fft_out_q[pilot_idx]
            all_pilots.append(rx_pilots)

            # Extract data
            rx_data = fft_out_q[data_idx]
            all_data.append(rx_data)

            # Channel estimation: LS at pilot positions
            h_at_pilots = rx_pilots / PILOT_VALUE

            # Interpolate channel to all used subcarriers
            all_used_idx = np.sort(np.concatenate([data_idx, pilot_idx]))
            h_est_interp = np.interp(
                all_used_idx.astype(float),
                pilot_idx.astype(float),
                np.abs(h_at_pilots)
            ) * np.exp(1j * np.interp(
                all_used_idx.astype(float),
                pilot_idx.astype(float),
                np.angle(h_at_pilots)
            ))

            # Map back to data-only indices
            data_in_used = np.array([np.searchsorted(all_used_idx, d) for d in data_idx])
            h_at_data = h_est_interp[data_in_used]
            h_at_data_q = quantize_complex_array(h_at_data)
            all_h_est.append(h_at_data_q)

            # Zero-forcing equalization
            h_safe = np.where(np.abs(h_at_data_q) > 1e-6, h_at_data_q, 1e-6)
            eq_data = rx_data / h_safe
            eq_data_q = quantize_complex_array(eq_data)
            all_eq_data.append(eq_data_q)

        after_cp_all = np.concatenate(all_after_cp)
        fft_out_all = np.concatenate(all_fft_out)
        pilots_all = np.concatenate(all_pilots)
        data_all = np.concatenate(all_data)
        h_est_all = np.concatenate(all_h_est)
        eq_data_all = np.concatenate(all_eq_data)

        print(f"  After CP: {len(after_cp_all)}, FFT: {len(fft_out_all)}, "
              f"Pilots: {len(pilots_all)}, Data: {len(data_all)}")
        print(f"  H_est: {len(h_est_all)}, EQ data: {len(eq_data_all)}")

        # -----------------------------------------------------------------
        # 7. Soft demapping -> LLRs
        # -----------------------------------------------------------------
        # Compute noise variance for soft demapping
        if snr_db == float('inf'):
            noise_var = 1e-10
        else:
            snr_linear = 10 ** (snr_db / 10.0)
            sig_power = np.mean(np.abs(tx_q.astype(np.complex128)) ** 2)
            noise_var = float(sig_power / snr_linear)

        # Use the quantized equalized symbols for demapping
        eq_for_demap = eq_data_all[:n_qam]
        # Pad with zeros if needed (last OFDM symbol padding)
        if len(eq_for_demap) < n_qam:
            eq_for_demap = np.concatenate([
                eq_for_demap,
                np.zeros(n_qam - len(eq_for_demap), dtype=np.complex64)
            ])

        soft_llr = qam_demap_soft(eq_for_demap, noise_var, "QPSK")
        # Trim to code length
        if len(soft_llr) > code.N:
            soft_llr = soft_llr[:code.N]
        elif len(soft_llr) < code.N:
            soft_llr = np.concatenate([
                soft_llr,
                np.zeros(code.N - len(soft_llr), dtype=np.float64)
            ])

        print(f"  LLRs: {len(soft_llr)}")

        # -----------------------------------------------------------------
        # 8. LDPC decode
        # -----------------------------------------------------------------
        result = dec.decode(soft_llr)
        decoded_bits = result['decoded_bits']
        decoded_info = decoded_bits[:code.K]
        ber = float(np.sum(decoded_info != info_bits) / code.K)
        print(f"  LDPC: converged={result['converged']}, "
              f"iters={result['num_iterations']}, BER={ber:.6f}")

        # -----------------------------------------------------------------
        # 9. Export hex files
        # -----------------------------------------------------------------
        def write_hex(filename, lines):
            path = os.path.join(output_dir, filename)
            with open(path, "w") as f:
                for line in lines:
                    f.write(line + "\n")
            return path

        # TX IQ: 560 lines
        p = write_hex(f"ofdm_tx_iq_{scn_name}.hex",
                       complex_array_to_hex(tx_q))
        print(f"  -> {os.path.basename(p)} ({len(tx_q)} lines)")

        # RX IQ: 560 lines
        p = write_hex(f"ofdm_rx_iq_{scn_name}.hex",
                       complex_array_to_hex(rx_q))
        print(f"  -> {os.path.basename(p)} ({len(rx_q)} lines)")

        # After CP removal: 7 x 64 = 448 lines
        p = write_hex(f"ofdm_after_cp_{scn_name}.hex",
                       complex_array_to_hex(after_cp_all))
        print(f"  -> {os.path.basename(p)} ({len(after_cp_all)} lines)")

        # FFT output: 7 x 64 = 448 lines
        p = write_hex(f"ofdm_fft_out_{scn_name}.hex",
                       complex_array_to_hex(fft_out_all))
        print(f"  -> {os.path.basename(p)} ({len(fft_out_all)} lines)")

        # Pilots: 7 x 4 = 28 lines
        p = write_hex(f"ofdm_pilots_{scn_name}.hex",
                       complex_array_to_hex(pilots_all))
        print(f"  -> {os.path.basename(p)} ({len(pilots_all)} lines)")

        # Data carriers: 7 x 48 = 336 lines
        p = write_hex(f"ofdm_data_{scn_name}.hex",
                       complex_array_to_hex(data_all))
        print(f"  -> {os.path.basename(p)} ({len(data_all)} lines)")

        # Channel estimates at data positions: 7 x 48 = 336 lines
        p = write_hex(f"ofdm_h_est_{scn_name}.hex",
                       complex_array_to_hex(h_est_all))
        print(f"  -> {os.path.basename(p)} ({len(h_est_all)} lines)")

        # Equalized data: 7 x 48 = 336 lines
        p = write_hex(f"ofdm_eq_data_{scn_name}.hex",
                       complex_array_to_hex(eq_data_all))
        print(f"  -> {os.path.basename(p)} ({len(eq_data_all)} lines)")

        # LLRs: 648 lines, 6-bit quantized
        llr_lines = [quantize_llr_6bit(v) for v in soft_llr]
        p = write_hex(f"ofdm_llr_{scn_name}_6bit.hex", llr_lines)
        print(f"  -> {os.path.basename(p)} ({len(llr_lines)} lines)")

        # Info bits: 324 lines (1 bit per line)
        info_lines = [str(int(b)) for b in info_bits]
        p = write_hex(f"ofdm_info_bits_{scn_name}.hex", info_lines)
        print(f"  -> {os.path.basename(p)} ({len(info_lines)} lines)")

        print()

    print("=== OFDM test vector generation complete ===")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(script_dir, "..", "test_vectors", "ofdm")
    generate_ofdm_vectors(out_dir)

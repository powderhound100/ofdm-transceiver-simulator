"""P6: Test vector generation for Rust and FPGA verification.

Generates vectors at 4 SNR points: -2.0, -0.5, +2.0, inf
Exports: float32 LLRs, 6-bit hex LLRs, decoded bits, per-iteration messages.
Fixed seed 42 for reproducibility.
"""

from __future__ import annotations

import json
import os
import numpy as np

from ldpc_code import make_wifi_code, QcLdpcCode
from encoder import LdpcEncoder
from decoder import MinSumDecoder
from channel import transmit


# 6-bit quantization: signed 2's complement, range [-31, +31]
def quantize_6bit(value: float) -> int:
    """Quantize float to 6-bit signed integer [-31, +31]."""
    q = int(round(np.clip(value, -31, 31)))
    return q


def to_6bit_hex(value: int) -> str:
    """Convert 6-bit signed integer to 2-char hex string (2's complement)."""
    if value < 0:
        value = (1 << 6) + value  # 2's complement
    return f"{value:02X}"


def from_6bit_hex(hex_str: str) -> int:
    """Convert 2-char hex string back to signed 6-bit integer."""
    v = int(hex_str, 16)
    if v >= 32:
        v -= 64
    return v


def snr_label(snr_db: float) -> str:
    """Generate filename-safe SNR label."""
    if snr_db == float('inf'):
        return "noiseless"
    if snr_db == -2.0:
        return "high_noise"
    if snr_db == -0.5:
        return "waterfall"
    if snr_db == 2.0:
        return "clean"
    # Generic
    s = f"{snr_db:.1f}".replace('-', 'm').replace('.', 'p')
    return f"snr_{s}"


def generate_test_vectors(output_dir: str = "../test_vectors"):
    """Generate all test vectors."""
    code = make_wifi_code()
    enc = LdpcEncoder(code)
    dec = MinSumDecoder(code, alpha=0.75, max_iter=50)

    os.makedirs(output_dir, exist_ok=True)

    # --- Export code definition files ---
    print("Exporting code definition...")

    # base_matrix.json
    bm_data = {
        "mb": code.mb,
        "nb": code.nb,
        "z": code.z,
        "entries": code.base_matrix
    }
    with open(os.path.join(output_dir, "base_matrix.json"), "w") as f:
        json.dump(bm_data, f, indent=2)

    # tanner_graph.json (convert numpy ints to Python ints for JSON)
    tg_data = {
        "cn_to_vn": [[int(v) for v in row] for row in code.cn_to_vn],
        "vn_to_cn": [[int(c) for c in row] for row in code.vn_to_cn],
    }
    with open(os.path.join(output_dir, "tanner_graph.json"), "w") as f:
        json.dump(tg_data, f)
    print(f"  base_matrix.json, tanner_graph.json written")

    # --- Generate per-SNR-point vectors ---
    snr_points = [-2.0, -0.5, 2.0, float('inf')]
    seed = 42

    rng = np.random.default_rng(seed)
    info_bits = rng.integers(0, 2, size=code.K, dtype=np.uint8)
    cw = enc.encode(info_bits)

    for snr_db in snr_points:
        label = snr_label(snr_db)
        print(f"\nSNR = {snr_db} dB (label: {label})")

        # Channel
        rng_ch = np.random.default_rng(seed)
        llr, sigma2 = transmit(cw, code.rate, snr_db, rng_ch)

        # Quantize to f32 and back to f64 so the decoder input matches
        # what Rust will see when loading the f32 test vector files.
        # This ensures bit-exact decoded output across implementations.
        llr_f32 = llr.astype(np.float32).astype(np.float64)

        # Decode with iteration capture (using f32-quantized LLR)
        result = dec.decode(llr_f32, capture_iterations=True)
        decoded = result['decoded_bits']
        num_iters = result['num_iterations']
        converged = result['converged']

        print(f"  Converged: {converged}, iterations: {num_iters}")
        bit_errors = np.sum(decoded != cw)
        print(f"  Bit errors: {bit_errors}/{code.N}")

        # --- Write files ---

        # llr_snr_<label>_f32.bin — N float32 values, little-endian
        f32_path = os.path.join(output_dir, f"llr_snr_{label}_f32.bin")
        with open(f32_path, "wb") as f:
            f.write(llr.astype(np.float32).tobytes())
        print(f"  {f32_path}")

        # llr_snr_<label>_6bit.hex — N lines of 2-char hex
        hex_path = os.path.join(output_dir, f"llr_snr_{label}_6bit.hex")
        with open(hex_path, "w") as f:
            for v in llr:
                q = quantize_6bit(v)
                f.write(to_6bit_hex(q) + "\n")
        print(f"  {hex_path}")

        # decoded_snr_<label>.bin — N uint8
        dec_path = os.path.join(output_dir, f"decoded_snr_{label}.bin")
        with open(dec_path, "wb") as f:
            f.write(decoded.tobytes())
        print(f"  {dec_path}")

        # info_bits_snr_<label>.bin — K uint8
        info_path = os.path.join(output_dir, f"info_bits_snr_{label}.bin")
        with open(info_path, "wb") as f:
            f.write(info_bits.tobytes())
        print(f"  {info_path}")

        # num_iters_snr_<label>.txt — single integer
        iter_path = os.path.join(output_dir, f"num_iters_snr_{label}.txt")
        with open(iter_path, "w") as f:
            f.write(str(num_iters) + "\n")
        print(f"  {iter_path}")

        # --- Per-iteration intermediate data ---
        iter_dir = os.path.join(output_dir, f"iter_messages_snr_{label}")
        os.makedirs(iter_dir, exist_ok=True)

        iter_data = result['iteration_data']
        for it_idx, it_data in enumerate(iter_data):
            # c2v_iter<NN>.hex — M lines, each line: space-separated hex per edge
            c2v_path = os.path.join(iter_dir, f"c2v_iter{it_idx:02d}.hex")
            with open(c2v_path, "w") as f:
                for c in range(code.M):
                    vals = it_data['c2v'][c]
                    hex_vals = [to_6bit_hex(quantize_6bit(v)) for v in vals]
                    f.write(" ".join(hex_vals) + "\n")

            # v2c_iter<NN>.hex — N lines, each line: space-separated hex per edge
            v2c_path = os.path.join(iter_dir, f"v2c_iter{it_idx:02d}.hex")
            with open(v2c_path, "w") as f:
                for v in range(code.N):
                    vals = it_data['v2c'][v]
                    hex_vals = [to_6bit_hex(quantize_6bit(v_val)) for v_val in vals]
                    f.write(" ".join(hex_vals) + "\n")

            # posterior_iter<NN>.hex — N lines of 2-char hex
            post_path = os.path.join(iter_dir, f"posterior_iter{it_idx:02d}.hex")
            with open(post_path, "w") as f:
                for v in it_data['posterior']:
                    f.write(to_6bit_hex(quantize_6bit(v)) + "\n")

            # syndrome_iter<NN>.txt — "PASS" or "FAIL"
            syn_path = os.path.join(iter_dir, f"syndrome_iter{it_idx:02d}.txt")
            with open(syn_path, "w") as f:
                f.write("PASS" if it_data['syndrome_pass'] else "FAIL")
                f.write("\n")

        print(f"  {len(iter_data)} iteration snapshots in {iter_dir}")

    print("\n--- Round-trip verification ---")
    verify_round_trip(output_dir, code, llr, decoded, info_bits)
    print("\n=== Test vector generation complete ===")


def verify_round_trip(output_dir: str, code: QcLdpcCode,
                      last_llr: np.ndarray, last_decoded: np.ndarray,
                      info_bits: np.ndarray):
    """Verify that exported files can be read back correctly."""
    # Check base_matrix.json
    with open(os.path.join(output_dir, "base_matrix.json")) as f:
        bm = json.load(f)
    assert bm["mb"] == code.mb
    assert bm["nb"] == code.nb
    assert bm["z"] == code.z
    assert bm["entries"] == code.base_matrix
    print("  base_matrix.json: PASS")

    # Check tanner_graph.json
    with open(os.path.join(output_dir, "tanner_graph.json")) as f:
        tg = json.load(f)
    assert tg["cn_to_vn"] == code.cn_to_vn
    assert tg["vn_to_cn"] == code.vn_to_cn
    print("  tanner_graph.json: PASS")

    # Check noiseless f32 LLR round-trip
    label = "noiseless"
    f32_path = os.path.join(output_dir, f"llr_snr_{label}_f32.bin")
    with open(f32_path, "rb") as f:
        llr_reload = np.frombuffer(f.read(), dtype=np.float32)
    # Compare against the noiseless LLR (regenerate to compare)
    assert llr_reload.shape == (code.N,)
    print(f"  llr_snr_{label}_f32.bin: shape OK")

    # Check 6-bit hex round-trip
    hex_path = os.path.join(output_dir, f"llr_snr_{label}_6bit.hex")
    with open(hex_path) as f:
        hex_lines = f.read().strip().split("\n")
    assert len(hex_lines) == code.N
    # Verify round-trip: hex -> int -> hex
    for line in hex_lines[:10]:
        val = from_6bit_hex(line.strip())
        assert -31 <= val <= 31, f"Out of range: {val}"
        assert to_6bit_hex(val) == line.strip()
    print(f"  llr_snr_{label}_6bit.hex: round-trip OK")

    # Check decoded bits
    dec_path = os.path.join(output_dir, f"decoded_snr_{label}.bin")
    with open(dec_path, "rb") as f:
        dec_reload = np.frombuffer(f.read(), dtype=np.uint8)
    assert dec_reload.shape == (code.N,)
    print(f"  decoded_snr_{label}.bin: shape OK")

    # Check info bits
    info_path = os.path.join(output_dir, f"info_bits_snr_{label}.bin")
    with open(info_path, "rb") as f:
        info_reload = np.frombuffer(f.read(), dtype=np.uint8)
    assert np.array_equal(info_reload, info_bits)
    print(f"  info_bits_snr_{label}.bin: exact match")


if __name__ == "__main__":
    generate_test_vectors(os.path.join(os.path.dirname(__file__), "..", "test_vectors"))

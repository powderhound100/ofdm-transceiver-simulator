"""Generate RTL BER sweep data via Python->hex->iverilog co-simulation.

For each SNR point:
  1. Python OFDM TX -> channel -> RX -> soft demap (float LLRs)
  2. Quantize to 6-bit signed -> hex file
  3. iverilog runs tb_ldpc_sweep.sv -> reads hex -> decodes -> prints bits
  4. Parse stdout -> compute BER
"""
import sys, os, json, subprocess, shutil, tempfile
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ofdm.params import OfdmParams
from ofdm.simulation import run_ofdm_chain
from ldpc_code import make_wifi_code


def quantize_llr_6bit(llr_float):
    """Quantize LLR to 6-bit signed [-31, +31], return hex string."""
    val = int(np.clip(np.round(llr_float), -31, 31))
    if val < 0:
        val = 64 + val
    return f"{val:02x}"


def run_rtl_decode(llr_array, tb_dir, tv_dir):
    """Write LLRs to hex, run iverilog, parse decoded bits.

    Returns (decoded_bits, converged, iterations) or None on failure.
    """
    # Write hex file
    hex_path = os.path.join(tv_dir, "rtl_sweep_llr.hex")
    with open(hex_path, "w") as f:
        for llr in llr_array:
            f.write(quantize_llr_6bit(llr) + "\n")

    # Run iverilog simulation
    vvp_path = os.path.join(tb_dir, "tb_ldpc_sweep.vvp")
    if not os.path.exists(vvp_path):
        # Compile first
        compile_cmd = [
            "iverilog", "-g2012", "-o", vvp_path,
            "-I", os.path.join(os.path.dirname(tb_dir), "rtl"),
            os.path.join(os.path.dirname(tb_dir), "tb", "tb_ldpc_sweep.sv"),
        ]
        # Add all RTL files
        rtl_dir = os.path.join(os.path.dirname(tb_dir), "rtl")
        for f in os.listdir(rtl_dir):
            if f.endswith(".sv"):
                compile_cmd.append(os.path.join(rtl_dir, f))
        subprocess.run(compile_cmd, check=True, capture_output=True)

    try:
        result = subprocess.run(
            ["vvp", vvp_path],
            capture_output=True, text=True, timeout=60,
            cwd=tb_dir,
        )
    except subprocess.TimeoutExpired:
        return None

    # Parse output
    decoded_bits = None
    converged = False
    iterations = 0

    for line in result.stdout.split("\n"):
        if line.startswith("DECODED:"):
            hex_str = line.split(":")[1].strip()
            # Convert hex string to bit array
            n_bits = len(hex_str) * 4
            val = int(hex_str, 16)
            decoded_bits = np.array([(val >> (n_bits - 1 - i)) & 1 for i in range(n_bits)], dtype=np.uint8)
        elif line.startswith("STATS:"):
            parts = line.split(":")[1].strip()
            for part in parts.split(","):
                k, v = part.split("=")
                if k.strip() == "converged":
                    converged = v.strip() == "1"
                elif k.strip() == "iters":
                    iterations = int(v.strip())

    if decoded_bits is not None:
        return decoded_bits, converged, iterations
    return None


def main():
    configs = [
        ("QPSK", "flat", "LMMSE"),
        ("QPSK", "tu6", "LMMSE"),
        ("64QAM", "flat", "LMMSE"),
        ("64QAM", "tu6", "LMMSE"),
        ("256QAM", "flat", "LMMSE"),
        ("256QAM", "tu6", "LMMSE"),
    ]
    snr_range = list(np.arange(0, 31, 1.0))
    seeds = [42, 43, 44]

    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tb_dir = os.path.join(base_dir, "fpga", "sim")
    tv_dir = os.path.join(base_dir, "test_vectors")

    code = make_wifi_code()
    results = {}

    for mod, ch, est in configs:
        key = f"{mod}_{ch}_{est}_RTL"
        print(f"\n=== {key} ===")
        curve = []
        zero_count = 0

        for snr in snr_range:
            ber_sum = 0.0
            n_valid = 0

            for seed in seeds:
                try:
                    r = run_ofdm_chain(
                        snr_db=float(snr), modulation=mod,
                        channel_model=ch, seed=seed,
                        estimator=est.replace("LMMSE", "LMMSE"),
                        equalizer="MMSE",
                    )

                    # Run RTL decode
                    rtl_result = run_rtl_decode(r.soft_llr, tb_dir, tv_dir)
                    if rtl_result is not None:
                        decoded_bits, converged, iters = rtl_result
                        info_bits = r.info_bits
                        n_check = min(len(decoded_bits), len(info_bits))
                        bit_errors = np.sum(decoded_bits[:n_check] != info_bits[:n_check])
                        ber = float(bit_errors) / n_check
                        ber_sum += ber
                        n_valid += 1
                    else:
                        ber_sum += 0.5
                        n_valid += 1
                except Exception as e:
                    print(f"  Error at SNR={snr}, seed={seed}: {e}")
                    ber_sum += 0.5
                    n_valid += 1

            avg_ber = ber_sum / max(n_valid, 1)
            point = {"snr_db": float(snr), "ber_coded": avg_ber}
            curve.append(point)
            print(f"  SNR={snr:>6.1f} dB | BER={avg_ber:.4e}")

            if avg_ber == 0:
                zero_count += 1
                if zero_count >= 5:
                    for remaining_snr in snr_range[snr_range.index(snr) + 1:]:
                        curve.append({"snr_db": float(remaining_snr), "ber_coded": 0.0})
                    break
            else:
                zero_count = 0

        results[key] = curve

        with open("rtl_ber_sweep_data.json", "w") as f:
            json.dump(results, f, indent=2)
        print(f"  [saved {len(results)} curves]")

    print(f"\nSaved to rtl_ber_sweep_data.json ({len(results)} curves)")


if __name__ == "__main__":
    main()

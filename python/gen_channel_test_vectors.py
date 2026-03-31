"""Channel model FIR filter test vector generator for FPGA verification.

For each of the 10 channel profiles, generates:
  - FIR tap coefficients (delay + Q1.14 coefficients)
  - 1024-sample complex sinusoid test input
  - Expected convolution output

All values quantized to Q1.14 fixed-point (16-bit signed, 14 fractional bits)
to match the FPGA channel_fir module.

Output under test_vectors/channel/.
"""
from __future__ import annotations

import os
import sys
import numpy as np

# Ensure the python/ directory is on the path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ofdm.channel_model import CHANNEL_MODELS, make_channel_taps


# =============================================================================
# Quantization helpers (matching FPGA Q1.14 format)
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


def q114_to_complex(re_int, im_int):
    """Convert Q1.14 integers back to complex float."""
    return (re_int / 2**14) + 1j * (im_int / 2**14)


def quantize_complex_array(arr):
    """Quantize complex array to Q1.14 and return the dequantized version."""
    out = np.empty(len(arr), dtype=np.complex128)
    for i, v in enumerate(arr):
        re, im = quantize_q114(v)
        out[i] = q114_to_complex(re, im)
    return out.astype(np.complex64)


def complex_array_to_hex(arr):
    """Convert complex array to list of 32-bit hex strings via Q1.14."""
    lines = []
    for v in arr:
        re, im = quantize_q114(v)
        lines.append(to_hex32(re, im))
    return lines


# =============================================================================
# All 10 channel profiles
# =============================================================================

ALL_PROFILES = [
    "flat",
    "two_tap",
    "tu6",
    "cost207_ra",
    "cost207_ht",
    "brazil_a",
    "brazil_b",
    "brazil_c",
    "brazil_d",
    "brazil_e",
]


# =============================================================================
# Main generator
# =============================================================================

def generate_channel_vectors(output_dir: str):
    """Generate channel FIR test vectors for all profiles."""
    os.makedirs(output_dir, exist_ok=True)

    n_samples = 1024
    freq_norm = 3.0 / 64.0  # normalized frequency: 3/64 of sample rate

    # -----------------------------------------------------------------
    # Generate shared test input: complex sinusoid at f = 3/64 * fs
    # x[n] = exp(j * 2 * pi * freq_norm * n)
    # -----------------------------------------------------------------
    n = np.arange(n_samples)
    test_input = np.exp(1j * 2 * np.pi * freq_norm * n).astype(np.complex64)

    # Quantize input to Q1.14
    test_input_q = quantize_complex_array(test_input)

    # Write shared input file
    input_hex = complex_array_to_hex(test_input_q)
    input_path = os.path.join(output_dir, "channel_fir_input.hex")
    with open(input_path, "w") as f:
        for line in input_hex:
            f.write(line + "\n")
    print(f"Input: {input_path} ({n_samples} samples)")
    print(f"  Sinusoid freq = {freq_norm:.6f} * fs = {freq_norm * 6e6:.0f} Hz\n")

    # -----------------------------------------------------------------
    # For each channel profile
    # -----------------------------------------------------------------
    for profile in ALL_PROFILES:
        print(f"--- Profile: {profile} ---")
        model = CHANNEL_MODELS[profile]
        delays = model["delays"]
        powers_db = model["powers_db"]

        # Get deterministic channel taps (all real, normalized)
        taps = make_channel_taps(profile, rng=None)
        print(f"  Taps: {len(taps)} total ({len(delays)} non-zero)")

        # --- Export tap coefficients ---
        # Format per non-zero tap: delay[7:0] + coeff_re[15:0] + coeff_im[15:0]
        # Packed as 10-char hex: delay(2) + re(4) + im(4)
        tap_lines = []
        for d, p_db in zip(delays, powers_db):
            tap_val = taps[d]
            re_q, im_q = quantize_q114(tap_val)
            delay_hex = f"{d & 0xFF:02x}"
            re_hex = f"{re_q & 0xFFFF:04x}"
            im_hex = f"{im_q & 0xFFFF:04x}"
            tap_lines.append(f"{delay_hex}{re_hex}{im_hex}")
            print(f"  tap[{d:>3d}] = {tap_val.real:+.6f}{tap_val.imag:+.6f}j "
                  f"-> Q1.14 re={re_q:>6d} im={im_q:>6d}")

        taps_path = os.path.join(output_dir, f"channel_fir_taps_{profile}.hex")
        with open(taps_path, "w") as f:
            for line in tap_lines:
                f.write(line + "\n")
        print(f"  -> {os.path.basename(taps_path)} ({len(tap_lines)} taps)")

        # --- Compute expected output ---
        # Convolve quantized input with quantized taps, then quantize output
        # Build the quantized tap impulse response
        taps_q = np.zeros(len(taps), dtype=np.complex128)
        for d, _ in zip(delays, powers_db):
            re_q, im_q = quantize_q114(taps[d])
            taps_q[d] = q114_to_complex(re_q, im_q)

        # Convolution (same mode, matching FPGA behavior)
        expected_output = np.convolve(
            test_input_q.astype(np.complex128),
            taps_q,
            mode='same'
        ).astype(np.complex64)

        # Quantize output
        expected_output_q = quantize_complex_array(expected_output)

        # Write expected output
        output_hex = complex_array_to_hex(expected_output_q)
        out_path = os.path.join(output_dir, f"channel_fir_expected_{profile}.hex")
        with open(out_path, "w") as f:
            for line in output_hex:
                f.write(line + "\n")
        print(f"  -> {os.path.basename(out_path)} ({n_samples} samples)")

        # Quick sanity: check energy ratio
        in_power = np.mean(np.abs(test_input_q.astype(np.complex128)) ** 2)
        out_power = np.mean(np.abs(expected_output_q.astype(np.complex128)) ** 2)
        print(f"  Power: in={in_power:.6f}, out={out_power:.6f}, "
              f"ratio={out_power/in_power:.4f}")
        print()

    print("=== Channel FIR test vector generation complete ===")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(script_dir, "..", "test_vectors", "channel")
    generate_channel_vectors(out_dir)

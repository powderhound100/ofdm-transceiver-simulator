"""P5: BER simulation harness.

Sweeps SNR from -3 to +3 dB, runs 100+ trials per point, prints BER/FER/avg_iter table.
Validates: monotonic BER decrease, visible waterfall.
"""

from __future__ import annotations

import sys
import numpy as np

from ldpc_code import make_wifi_code
from encoder import LdpcEncoder
from decoder import MinSumDecoder
from channel import transmit


def run_ber_sweep(snr_range: list[float], num_trials: int = 100,
                  base_seed: int = 42, max_iter: int = 50,
                  alpha: float = 0.75) -> list[dict]:
    """Run BER simulation across SNR range.

    Returns list of dicts with fields:
      snr_db, ber, fer, avg_iter, num_trials
    """
    code = make_wifi_code()
    enc = LdpcEncoder(code)
    dec = MinSumDecoder(code, alpha=alpha, max_iter=max_iter)

    results = []

    for snr_db in snr_range:
        total_bit_errors = 0
        total_frame_errors = 0
        total_iterations = 0
        total_info_bits = 0

        for trial in range(num_trials):
            seed = base_seed + trial * 1000 + int((snr_db + 50) * 100)
            rng = np.random.default_rng(seed)

            info_bits = rng.integers(0, 2, size=code.K, dtype=np.uint8)
            cw = enc.encode(info_bits)

            llr, _ = transmit(cw, code.rate, snr_db, rng)
            result = dec.decode(llr)

            # Count errors in info bits only
            decoded_info = result['decoded_bits'][:code.K]
            bit_errors = np.sum(decoded_info != info_bits)
            total_bit_errors += bit_errors
            total_frame_errors += (1 if bit_errors > 0 else 0)
            total_iterations += result['num_iterations']
            total_info_bits += code.K

        ber = total_bit_errors / total_info_bits if total_info_bits > 0 else 0.0
        fer = total_frame_errors / num_trials
        avg_iter = total_iterations / num_trials

        results.append({
            'snr_db': snr_db,
            'ber': ber,
            'fer': fer,
            'avg_iter': avg_iter,
            'num_trials': num_trials,
        })

    return results


def print_results(results: list[dict]):
    """Print BER sweep results as a formatted table."""
    print(f"{'SNR(dB)':>8} {'BER':>12} {'FER':>8} {'AvgIter':>8} {'Trials':>7}")
    print("-" * 50)
    for r in results:
        ber_str = f"{r['ber']:.2e}" if r['ber'] > 0 else "0.00e+00"
        print(f"{r['snr_db']:>8.1f} {ber_str:>12} {r['fer']:>8.3f} "
              f"{r['avg_iter']:>8.1f} {r['num_trials']:>7}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== P5: BER Simulation ===\n")
    print("802.11n rate-1/2 N=648 Z=27, NMS alpha=0.75, max_iter=50\n")

    snr_range = [-3.0, -2.0, -1.0, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
    num_trials = 100

    results = run_ber_sweep(snr_range, num_trials=num_trials)
    print_results(results)

    # Validation: BER should be monotonically non-increasing
    print("\n--- Validation ---")
    bers = [r['ber'] for r in results]
    monotonic = all(bers[i] >= bers[i+1] - 1e-10 for i in range(len(bers)-1))
    print(f"BER monotonic decrease: {'PASS' if monotonic else 'FAIL'}")

    # Waterfall: BER should drop significantly between low and high SNR
    ber_low = results[0]['ber']   # -3 dB
    ber_high = results[-1]['ber']  # +3 dB
    has_waterfall = ber_low > 0.01 and ber_high < 0.01
    print(f"Waterfall visible (BER@-3dB > 0.01 and BER@3dB < 0.01): "
          f"{'PASS' if has_waterfall else 'FAIL'}")
    print(f"  BER@-3dB = {ber_low:.4e}, BER@3dB = {ber_high:.4e}")

    # Avg iterations should decrease with SNR
    avg_iters = [r['avg_iter'] for r in results]
    iter_trend = avg_iters[0] > avg_iters[-1]
    print(f"Avg iterations decrease with SNR: {'PASS' if iter_trend else 'FAIL'}")
    print(f"  Avg iter @ -3dB = {avg_iters[0]:.1f}, @ 3dB = {avg_iters[-1]:.1f}")

    if monotonic and has_waterfall and iter_trend:
        print("\n=== All P5 validations PASSED ===")
    else:
        print("\n=== Some P5 validations FAILED ===")
        sys.exit(1)

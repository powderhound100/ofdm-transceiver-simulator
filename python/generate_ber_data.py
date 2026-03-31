"""Generate comprehensive BER sweep data across all modulations and channels.

SNR range: -40 to +20 dB (coarse steps at very low SNR, fine near waterfall).
"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from ofdm.simulation import run_ofdm_chain

# SNR range: -40 to +20 dB
#   -40 to -6: 2 dB steps (18 points) — BER ≈ 0.5 (noise floor)
#   -5 to +20: 1 dB steps (26 points) — waterfall region
snr_range = list(np.arange(-40, -5, 2.0)) + list(np.arange(-5, 21, 1.0))
modulations = ["QPSK", "16QAM", "64QAM"]
channels = ["flat", "two_tap", "tu6"]

results = {}
for mod in modulations:
    for ch in channels:
        key = f"{mod}_{ch}"
        print(f"\n=== {key} ===")
        curve = []
        for snr in snr_range:
            # Average over 3 seeds for smoother curves
            ber_sum = 0.0
            ber_unc_sum = 0.0
            iter_sum = 0
            conv_count = 0
            n_seeds = 3
            for seed in range(42, 42 + n_seeds):
                try:
                    r = run_ofdm_chain(snr_db=float(snr), modulation=mod,
                                       channel_model=ch, seed=seed)
                    ber_sum += r.ber_coded
                    ber_unc_sum += r.ber_uncoded
                    iter_sum += r.ldpc_iterations
                    if r.ldpc_converged:
                        conv_count += 1
                except Exception as e:
                    print(f"  Error at SNR={snr}, seed={seed}: {e}")
                    ber_sum += 0.5
                    ber_unc_sum += 0.5
                    iter_sum += 50

            point = {
                "snr_db": float(snr),
                "ber_coded": ber_sum / n_seeds,
                "ber_uncoded": ber_unc_sum / n_seeds,
                "avg_iter": iter_sum / n_seeds,
                "fer": 1.0 - conv_count / n_seeds,
            }
            curve.append(point)
            status = "CONV" if conv_count == n_seeds else ("PART" if conv_count > 0 else "FAIL")
            print(f"  SNR={snr:>6.1f} dB | {status} | BER={point['ber_coded']:.4e} | uncoded={point['ber_uncoded']:.4e} | iter={point['avg_iter']:.1f}")

        results[key] = curve

    # Save after each mod/channel group (resilient to crashes)
    with open("ber_sweep_data.json", "w") as f:
        json.dump(results, f, indent=2)
    print(f"  [saved {len(results)} curves so far]")

# Also include the original BPSK+AWGN baseline from test_ber.py
print("\n=== BPSK baseline ===")
from test_ber import run_ber_sweep
bpsk_snr = list(np.arange(-40, -5, 2.0)) + list(np.arange(-5, 8, 0.5))
bpsk_data = run_ber_sweep(bpsk_snr, num_trials=50)
results["BPSK_baseline"] = bpsk_data
print("Done.")

with open("ber_sweep_data.json", "w") as f:
    json.dump(results, f, indent=2)
print(f"\nSaved to ber_sweep_data.json ({len(results)} curves)")

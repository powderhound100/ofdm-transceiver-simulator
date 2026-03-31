"""Generate comprehensive BER sweep data across all modulations, channels, and estimators.

SNR range: -40 to +30 dB (coarse steps at very low SNR, fine near waterfall).
Modulations: QPSK through 2048QAM.
Channels: flat, two_tap, tu6, COST 207, Brazil A-E.
Estimators: LS/ZF, LS_improved/ZF, LMMSE/MMSE.

Runtime optimisations:
  - Smart SNR start per modulation (skip obvious BER=0.5 region)
  - Early termination after 5 consecutive zero-BER points
  - Incremental JSON save after each (mod, channel) group
  - Multiprocessing pool (3 workers) across seeds
"""
import sys, os, json
from multiprocessing import Pool
from functools import partial
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np
from ofdm.simulation import run_ofdm_chain

# ---------------------------------------------------------------------------
# Sweep configuration
# ---------------------------------------------------------------------------
snr_range = list(np.arange(-40, -5, 2.0)) + list(np.arange(-5, 31, 1.0))

modulations = ["QPSK", "16QAM", "64QAM", "256QAM", "512QAM", "1024QAM", "2048QAM"]

channels = ["flat", "two_tap", "tu6", "cost207_ra", "cost207_ht",
            "brazil_a", "brazil_b", "brazil_c", "brazil_d", "brazil_e"]

estimators = [("LS", "ZF"), ("LS_improved", "ZF"), ("LMMSE", "MMSE")]

# Smart SNR start: skip the deeply-negative region where BER is trivially 0.5
SNR_START = {
    "QPSK": -40, "16QAM": -30, "64QAM": -20, "256QAM": -10,
    "512QAM": -5, "1024QAM": 0, "2048QAM": 5,
}

N_SEEDS = 3
SEED_BASE = 42
ZERO_BER_PATIENCE = 5  # stop after this many consecutive ber_coded == 0

OUTPUT_FILE = "ber_sweep_data.json"


# ---------------------------------------------------------------------------
# Worker function for multiprocessing
# ---------------------------------------------------------------------------
def _run_one_seed(seed, snr_db, mod, ch, est, eq):
    """Run a single seed and return (ber_coded, ber_uncoded, iterations, converged)."""
    try:
        r = run_ofdm_chain(snr_db=float(snr_db), modulation=mod,
                           channel_model=ch, seed=seed,
                           estimator=est, equalizer=eq)
        return (r.ber_coded, r.ber_uncoded, r.ldpc_iterations, r.ldpc_converged)
    except Exception as e:
        print(f"  Error at SNR={snr_db}, seed={seed}: {e}")
        return (0.5, 0.5, 50, False)


# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------
def main():
    # Load existing results if file exists (resume support)
    if os.path.exists(OUTPUT_FILE):
        with open(OUTPUT_FILE) as f:
            results = json.load(f)
        print(f"Loaded {len(results)} existing curves from {OUTPUT_FILE}")
    else:
        results = {}

    pool = Pool(3)

    for mod in modulations:
        snr_start = SNR_START[mod]
        active_snrs = [s for s in snr_range if s >= snr_start]

        for ch in channels:
            for est, eq in estimators:
                key = f"{mod}_{ch}_{est}"
                if key in results:
                    print(f"Skipping {key} (already computed)")
                    continue

                print(f"\n=== {key} (eq={eq}) ===")
                curve = []
                consecutive_zero = 0

                for snr in active_snrs:
                    if consecutive_zero >= ZERO_BER_PATIENCE:
                        # Fill remaining points with zero BER
                        point = {
                            "snr_db": float(snr),
                            "ber_coded": 0.0,
                            "ber_uncoded": 0.0,
                            "avg_iter": 0.0,
                            "fer": 0.0,
                        }
                        curve.append(point)
                        continue

                    # Parallel execution across seeds
                    fn = partial(_run_one_seed, snr_db=snr, mod=mod, ch=ch,
                                 est=est, eq=eq)
                    seed_results = pool.map(fn, range(SEED_BASE, SEED_BASE + N_SEEDS))

                    ber_sum = sum(r[0] for r in seed_results)
                    ber_unc_sum = sum(r[1] for r in seed_results)
                    iter_sum = sum(r[2] for r in seed_results)
                    conv_count = sum(1 for r in seed_results if r[3])

                    ber_coded_avg = ber_sum / N_SEEDS
                    point = {
                        "snr_db": float(snr),
                        "ber_coded": ber_coded_avg,
                        "ber_uncoded": ber_unc_sum / N_SEEDS,
                        "avg_iter": iter_sum / N_SEEDS,
                        "fer": 1.0 - conv_count / N_SEEDS,
                    }
                    curve.append(point)

                    # Early termination tracking
                    if ber_coded_avg == 0.0:
                        consecutive_zero += 1
                    else:
                        consecutive_zero = 0

                    status = ("CONV" if conv_count == N_SEEDS
                              else ("PART" if conv_count > 0 else "FAIL"))
                    print(f"  SNR={snr:>6.1f} dB | {status} | "
                          f"BER={point['ber_coded']:.4e} | "
                          f"uncoded={point['ber_uncoded']:.4e} | "
                          f"iter={point['avg_iter']:.1f}")

                results[key] = curve

            # Incremental save after each (mod, channel) group
            with open(OUTPUT_FILE, "w") as f:
                json.dump(results, f, indent=2)
            print(f"  [saved {len(results)} curves so far]")

    pool.close()
    pool.join()

    # -----------------------------------------------------------------------
    # BPSK baseline (extended to +30 dB, 0.5 dB steps)
    # -----------------------------------------------------------------------
    print("\n=== BPSK baseline ===")
    from test_ber import run_ber_sweep
    bpsk_snr = list(np.arange(-40, -5, 2.0)) + list(np.arange(-5, 31, 0.5))
    bpsk_data = run_ber_sweep(bpsk_snr, num_trials=50)
    results["BPSK_baseline"] = bpsk_data
    print("Done.")

    with open(OUTPUT_FILE, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nSaved to {OUTPUT_FILE} ({len(results)} curves)")


if __name__ == "__main__":
    main()

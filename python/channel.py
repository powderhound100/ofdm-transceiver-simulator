"""P3: BPSK modulation, AWGN channel, LLR computation.

BPSK: 0 → +1.0, 1 → -1.0
AWGN: sigma² = 1 / (2 * R * 10^(SNR_dB/10))
LLR:  2 * received / sigma²  (positive → bit probably 0)
"""

from __future__ import annotations

import numpy as np

from ldpc_code import QcLdpcCode, make_wifi_code
from encoder import LdpcEncoder


def bpsk_modulate(bits: np.ndarray) -> np.ndarray:
    """Map bits to BPSK symbols: 0 → +1.0, 1 → -1.0."""
    return 1.0 - 2.0 * bits.astype(np.float64)


def awgn_channel(signal: np.ndarray, sigma2: float,
                 rng: np.random.Generator) -> np.ndarray:
    """Add AWGN noise with variance sigma² to signal."""
    noise = rng.normal(0.0, np.sqrt(sigma2), size=signal.shape)
    return signal + noise


def compute_sigma2(code_rate: float, snr_db: float) -> float:
    """Compute noise variance from code rate and SNR in dB.

    sigma² = 1 / (2 * R * 10^(SNR_dB/10))
    """
    if snr_db == float('inf'):
        return 0.0
    snr_linear = 10.0 ** (snr_db / 10.0)
    return 1.0 / (2.0 * code_rate * snr_linear)


def compute_llr(received: np.ndarray, sigma2: float) -> np.ndarray:
    """Compute log-likelihood ratios from received BPSK signal.

    LLR = 2 * r / sigma²
    Positive LLR → bit 0 more likely
    Negative LLR → bit 1 more likely
    """
    if sigma2 == 0.0:
        # Noiseless: use large finite LLR with correct sign
        return np.sign(received) * 1000.0
    return 2.0 * received / sigma2


def transmit(codeword: np.ndarray, code_rate: float, snr_db: float,
             rng: np.random.Generator) -> tuple[np.ndarray, float]:
    """Full channel pipeline: BPSK → AWGN → LLR.

    Returns (channel_llr, sigma2).
    """
    bpsk = bpsk_modulate(codeword)
    sigma2 = compute_sigma2(code_rate, snr_db)

    if sigma2 == 0.0:
        received = bpsk.copy()
    else:
        received = awgn_channel(bpsk, sigma2, rng)

    llr = compute_llr(received, sigma2)
    return llr, sigma2


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== P3: BPSK + AWGN + LLR Tests ===\n")

    code = make_wifi_code()
    enc = LdpcEncoder(code)
    rng = np.random.default_rng(42)

    info_bits = rng.integers(0, 2, size=code.K, dtype=np.uint8)
    cw = enc.encode(info_bits)

    # Test 1: BPSK mapping
    print("Test 1: BPSK mapping...")
    bpsk = bpsk_modulate(cw)
    assert np.all(bpsk[cw == 0] == +1.0), "0 should map to +1"
    assert np.all(bpsk[cw == 1] == -1.0), "1 should map to -1"
    print("  PASS")

    # Test 2: High SNR — sign correctness
    print("Test 2: High SNR (10 dB) sign correctness...")
    llr, sigma2 = transmit(cw, code.rate, 10.0, np.random.default_rng(42))
    # At high SNR, LLR signs should match BPSK signs
    hard_decisions = (llr < 0).astype(np.uint8)
    bit_errors = np.sum(hard_decisions != cw)
    error_rate = bit_errors / code.N
    print(f"  sigma²={sigma2:.6f}, bit errors={bit_errors}/{code.N}, "
          f"error rate={error_rate:.6f}")
    assert error_rate < 0.001, f"Error rate too high at 10 dB: {error_rate}"
    print("  PASS: >99.9% sign correctness")

    # Test 3: Noise variance check
    print("Test 3: Noise variance within 5%...")
    snr_db = 0.0
    sigma2_expected = compute_sigma2(code.rate, snr_db)
    num_samples = 100000
    rng_test = np.random.default_rng(123)
    noise = rng_test.normal(0.0, np.sqrt(sigma2_expected), size=num_samples)
    measured_var = np.var(noise)
    rel_error = abs(measured_var - sigma2_expected) / sigma2_expected
    print(f"  Expected sigma2={sigma2_expected:.6f}, measured={measured_var:.6f}, "
          f"relative error={rel_error:.4f}")
    assert rel_error < 0.05, f"Noise variance error too large: {rel_error}"
    print("  PASS")

    # Test 4: Noiseless channel (inf SNR)
    print("Test 4: Noiseless channel (inf SNR)...")
    llr_inf, sigma2_inf = transmit(cw, code.rate, float('inf'),
                                    np.random.default_rng(42))
    assert sigma2_inf == 0.0
    hard_inf = (llr_inf < 0).astype(np.uint8)
    assert np.array_equal(hard_inf, cw), "Noiseless should have zero errors"
    print("  PASS: Perfect recovery")

    # Test 5: LLR magnitude increases with SNR
    print("Test 5: LLR magnitude increases with SNR...")
    snrs = [-2.0, 0.0, 2.0, 5.0, 10.0]
    mean_abs_llr = []
    for snr in snrs:
        llr_t, _ = transmit(cw, code.rate, snr, np.random.default_rng(42))
        mean_abs_llr.append(np.mean(np.abs(llr_t)))
    for i in range(len(snrs) - 1):
        assert mean_abs_llr[i + 1] > mean_abs_llr[i], (
            f"Mean |LLR| should increase: SNR={snrs[i]}→{snrs[i+1]}, "
            f"mean={mean_abs_llr[i]:.2f}→{mean_abs_llr[i+1]:.2f}")
    print(f"  Mean |LLR|: {[f'{v:.2f}' for v in mean_abs_llr]}")
    print("  PASS: Monotonically increasing")

    print("\n=== All P3 tests PASSED ===")

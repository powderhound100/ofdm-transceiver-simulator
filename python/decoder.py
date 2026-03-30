"""P4: Normalized Min-Sum LDPC decoder.

Flooding schedule, alpha=0.75, max_iter=50, early termination on zero syndrome.
Uses pre-computed edge cross-reference maps from QcLdpcCode for O(edges) complexity.
Captures per-iteration state for test vector export.
"""

from __future__ import annotations

import numpy as np

from ldpc_code import QcLdpcCode, make_wifi_code
from encoder import LdpcEncoder
from channel import transmit


class MinSumDecoder:
    """Normalized Min-Sum LDPC decoder with flooding schedule."""

    def __init__(self, code: QcLdpcCode, alpha: float = 0.75, max_iter: int = 50):
        self.code = code
        self.alpha = alpha
        self.max_iter = max_iter
        self.M = code.M
        self.N = code.N

        # Pre-build edge index structures for fast message passing.
        # c2v_edges[c] = list of (v, cn_edge_idx, vn_edge_idx) for check c
        # vn_edges[v] = list of (c, cn_edge_idx, vn_edge_idx) for var v
        self._c2v_edges: list[list[tuple[int, int, int]]] = [[] for _ in range(self.M)]
        self._vn_edges: list[list[tuple[int, int, int]]] = [[] for _ in range(self.N)]

        for c in range(self.M):
            for j, v in enumerate(code.cn_to_vn[c]):
                _, vn_idx = code.cn_edge_map[(c, v)]
                self._c2v_edges[c].append((v, j, vn_idx))

        for v in range(self.N):
            for i, c in enumerate(code.vn_to_cn[v]):
                cn_idx, _ = code.cn_edge_map[(c, v)]
                self._vn_edges[v].append((c, cn_idx, i))

    def decode(self, channel_llr: np.ndarray, *,
               capture_iterations: bool = False
               ) -> dict:
        """Decode channel LLRs using normalized min-sum.

        Returns dict with:
          decoded_bits: np.ndarray[uint8] shape (N,)
          num_iterations: int
          converged: bool
          iteration_data: list of dicts (if capture_iterations=True)
        """
        M, N = self.M, self.N
        alpha = self.alpha
        cn_to_vn = self.code.cn_to_vn
        vn_to_cn = self.code.vn_to_cn

        # Initialize c2v messages to 0
        # c2v[c][j] = message from check c to its j-th variable
        c2v: list[np.ndarray] = [
            np.zeros(len(cn_to_vn[c]), dtype=np.float64) for c in range(M)
        ]

        iteration_data = []

        for it in range(self.max_iter):
            # ----- Variable Node Update (VNU) -----
            # v2c[v][i] = channel_llr[v] + sum(c2v into v) - c2v[c_i][edge_to_v]
            # posterior[v] = channel_llr[v] + sum(c2v into v)
            posterior = np.zeros(N, dtype=np.float64)
            v2c: list[np.ndarray] = [
                np.zeros(len(vn_to_cn[v]), dtype=np.float64) for v in range(N)
            ]

            for v in range(N):
                # Sum all incoming c2v messages
                total = channel_llr[v]
                for c, cn_idx, vn_idx in self._vn_edges[v]:
                    total += c2v[c][cn_idx]
                posterior[v] = total

                # Extrinsic: subtract each incoming c2v
                for c, cn_idx, vn_idx in self._vn_edges[v]:
                    v2c[v][vn_idx] = total - c2v[c][cn_idx]

            # Hard decision and syndrome check
            hard_bits = (posterior < 0).astype(np.uint8)
            syndrome = np.zeros(M, dtype=np.uint8)
            for c in range(M):
                s = 0
                for v in cn_to_vn[c]:
                    s ^= hard_bits[v]
                syndrome[c] = s
            converged = np.all(syndrome == 0)

            # Capture iteration state if requested
            if capture_iterations:
                iteration_data.append({
                    'c2v': [arr.copy() for arr in c2v],
                    'v2c': [arr.copy() for arr in v2c],
                    'posterior': posterior.copy(),
                    'hard_bits': hard_bits.copy(),
                    'syndrome_pass': bool(converged),
                })

            if converged:
                return {
                    'decoded_bits': hard_bits,
                    'num_iterations': it + 1,
                    'converged': True,
                    'iteration_data': iteration_data,
                }

            # ----- Check Node Update (CNU) — Normalized Min-Sum -----
            for c in range(M):
                edges = self._c2v_edges[c]
                degree = len(edges)

                # Gather incoming v2c for this check node
                incoming = np.empty(degree, dtype=np.float64)
                for j, (v, cn_idx, vn_idx) in enumerate(edges):
                    incoming[j] = v2c[v][vn_idx]

                signs = np.sign(incoming)
                magnitudes = np.abs(incoming)

                # Product of signs
                sign_product = 1.0
                for s in signs:
                    sign_product *= s

                # Find min1, min2, argmin1
                sorted_idx = np.argsort(magnitudes)
                min1 = magnitudes[sorted_idx[0]]
                min2 = magnitudes[sorted_idx[1]] if degree > 1 else min1
                argmin1 = sorted_idx[0]

                # Compute c2v messages
                for j in range(degree):
                    ext_sign = sign_product * signs[j]
                    mag = min2 if j == argmin1 else min1
                    c2v[c][j] = alpha * ext_sign * mag

        # Did not converge
        # Final VNU for hard decision
        posterior = np.zeros(N, dtype=np.float64)
        for v in range(N):
            total = channel_llr[v]
            for c, cn_idx, vn_idx in self._vn_edges[v]:
                total += c2v[c][cn_idx]
            posterior[v] = total

        hard_bits = (posterior < 0).astype(np.uint8)

        if capture_iterations:
            v2c_final: list[np.ndarray] = [
                np.zeros(len(vn_to_cn[v]), dtype=np.float64) for v in range(N)
            ]
            for v in range(N):
                total = posterior[v]
                for c, cn_idx, vn_idx in self._vn_edges[v]:
                    v2c_final[v][vn_idx] = total - c2v[c][cn_idx]

            syndrome = np.zeros(M, dtype=np.uint8)
            for c in range(M):
                s = 0
                for v in cn_to_vn[c]:
                    s ^= hard_bits[v]
                syndrome[c] = s

            iteration_data.append({
                'c2v': [arr.copy() for arr in c2v],
                'v2c': [arr.copy() for arr in v2c_final],
                'posterior': posterior.copy(),
                'hard_bits': hard_bits.copy(),
                'syndrome_pass': bool(np.all(syndrome == 0)),
            })

        return {
            'decoded_bits': hard_bits,
            'num_iterations': self.max_iter,
            'converged': False,
            'iteration_data': iteration_data,
        }


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== P4: Normalized Min-Sum Decoder Tests ===\n")
    code = make_wifi_code()
    enc = LdpcEncoder(code)
    dec = MinSumDecoder(code, alpha=0.75, max_iter=50)

    rng = np.random.default_rng(42)
    info_bits = rng.integers(0, 2, size=code.K, dtype=np.uint8)
    cw = enc.encode(info_bits)

    # Test 1: Noiseless — should converge in 1 iteration
    print("Test 1: Noiseless decode (inf SNR)...")
    llr_inf, _ = transmit(cw, code.rate, float('inf'), np.random.default_rng(99))
    result = dec.decode(llr_inf)
    assert result['converged'], "Should converge on noiseless input"
    assert result['num_iterations'] == 1, (
        f"Noiseless should converge in 1 iter, got {result['num_iterations']}")
    assert np.array_equal(result['decoded_bits'], cw), "Decoded should match codeword"
    print(f"  PASS: Converged in {result['num_iterations']} iteration(s)")

    # Test 2: Decode at 2.0 dB (clean signal)
    print("Test 2: Decode at 2.0 dB (clean)...")
    llr_clean, _ = transmit(cw, code.rate, 2.0, np.random.default_rng(42))
    result_clean = dec.decode(llr_clean)
    print(f"  Converged: {result_clean['converged']}, "
          f"iterations: {result_clean['num_iterations']}")
    if result_clean['converged']:
        assert np.array_equal(result_clean['decoded_bits'], cw)
        print("  PASS: Decoded correctly")
    else:
        bit_errors = np.sum(result_clean['decoded_bits'] != cw)
        print(f"  Did not converge. Bit errors: {bit_errors}/{code.N}")

    # Test 3: Decode at 0 dB
    print("Test 3: Decode at 0.0 dB...")
    llr_0db, _ = transmit(cw, code.rate, 0.0, np.random.default_rng(42))
    result_0db = dec.decode(llr_0db)
    print(f"  Converged: {result_0db['converged']}, "
          f"iterations: {result_0db['num_iterations']}")
    if result_0db['converged']:
        assert np.array_equal(result_0db['decoded_bits'], cw)
        print("  PASS: Decoded correctly")
    else:
        bit_errors = np.sum(result_0db['decoded_bits'] != cw)
        print(f"  Bit errors: {bit_errors}/{code.N}")

    # Test 4: All-zero codeword noiseless
    print("Test 4: All-zero codeword noiseless...")
    cw_zero = np.zeros(code.N, dtype=np.uint8)
    llr_zero = np.ones(code.N, dtype=np.float64) * 1000.0  # strong +LLR = bit 0
    result_zero = dec.decode(llr_zero)
    assert result_zero['converged'], "All-zero should converge"
    assert result_zero['num_iterations'] == 1
    assert np.all(result_zero['decoded_bits'] == 0)
    print("  PASS: Converged in 1 iteration")

    # Test 5: Capture iteration data
    print("Test 5: Iteration capture at -0.5 dB...")
    llr_noisy, _ = transmit(cw, code.rate, -0.5, np.random.default_rng(42))
    result_cap = dec.decode(llr_noisy, capture_iterations=True)
    n_iters = len(result_cap['iteration_data'])
    print(f"  Captured {n_iters} iterations, converged={result_cap['converged']}")
    if n_iters > 0:
        it0 = result_cap['iteration_data'][0]
        print(f"  Iter 0 syndrome: {'PASS' if it0['syndrome_pass'] else 'FAIL'}")
        print(f"  Iter 0 c2v edges: {sum(len(a) for a in it0['c2v'])}")
    print("  PASS")

    print("\n=== All P4 tests PASSED ===")

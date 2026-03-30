"""P1: QC-LDPC code definition — base matrix, sparse expansion, Tanner graph.

Supports two input formats:
  Format A: Standard QC base matrix (e.g., IEEE 802.11n rate-1/2 N=648 Z=27)
  Format B: ATSC 3.0 accumulator address tables (from gr-atsc3)

Expands to full parity-check matrix H (scipy.sparse.csc_matrix) and extracts
Tanner graph adjacency lists with pre-computed edge cross-reference maps.
"""

from __future__ import annotations

import numpy as np
import scipy.sparse as sp

# ---------------------------------------------------------------------------
# IEEE 802.11n rate-1/2, N=648, Z=27 base matrix (Table R1 from the spec)
# 12×24 base matrix, entries are -1 (no edge) or circulant shift value 0..26
# ---------------------------------------------------------------------------
WIFI_R12_648_BASE = [
    [ 0, -1, -1, -1,  0,  0, -1, -1,  0, -1, -1,  0,  1,  0, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1],
    [22,  0, -1, -1, 17, -1,  0,  0, 12, -1, -1, -1, -1,  0,  0, -1, -1, -1, -1, -1, -1, -1, -1, -1],
    [ 6, -1,  0, -1, 10, -1, -1, -1, 24, -1,  0, -1, -1, -1,  0,  0, -1, -1, -1, -1, -1, -1, -1, -1],
    [ 2, -1, -1,  0, 20, -1, -1, -1, 25,  0, -1, -1, -1, -1, -1,  0,  0, -1, -1, -1, -1, -1, -1, -1],
    [23, -1, -1, -1,  3, -1, -1, -1,  0, -1,  9, 11, -1, -1, -1, -1,  0,  0, -1, -1, -1, -1, -1, -1],
    [24, -1, 23,  1, 17, -1,  3, -1, 10, -1, -1, -1, -1, -1, -1, -1, -1,  0,  0, -1, -1, -1, -1, -1],
    [25, -1, -1, -1,  8, -1, -1, -1,  7, 18, -1, -1,  0, -1, -1, -1, -1, -1,  0,  0, -1, -1, -1, -1],
    [13, 24, -1, -1,  0, -1,  8, -1,  6, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  0, -1, -1, -1],
    [ 7, 20, -1, 16, 22, 10, -1, -1, 23, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  0, -1, -1],
    [11, -1, -1, -1, 19, -1, -1, -1, 13, -1,  3, 17, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  0, -1],
    [25, -1,  8, -1, 23, 18, -1, 14,  9, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0,  0],
    [ 3, -1, -1, -1, 16, -1, -1,  2, 25,  5, -1, -1,  1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1,  0],
]
WIFI_R12_648_Z = 27


class QcLdpcCode:
    """QC-LDPC code with expanded H matrix and Tanner graph.

    Construction via class methods:
      QcLdpcCode.from_base_matrix(base_matrix, z)   — Format A
      QcLdpcCode.from_atsc3_table(...)               — Format B (future)
    """

    def __init__(self, H: sp.csc_matrix, mb: int, nb: int, z: int,
                 base_matrix: list[list[int]] | None = None):
        self.H = H
        self.mb = mb
        self.nb = nb
        self.z = z
        self.M, self.N = H.shape
        self.K = self.N - self.M
        self.rate = self.K / self.N
        self.base_matrix = base_matrix

        # Build Tanner graph
        self._build_tanner_graph()

    # -----------------------------------------------------------------------
    # Format A: Standard QC base matrix
    # -----------------------------------------------------------------------
    @classmethod
    def from_base_matrix(cls, base_matrix: list[list[int]], z: int) -> QcLdpcCode:
        """Construct from a QC base matrix where entries are -1 (no edge) or
        circulant shift values 0..z-1."""
        mb = len(base_matrix)
        nb = len(base_matrix[0])
        M = mb * z
        N = nb * z

        rows: list[int] = []
        cols: list[int] = []
        for r in range(mb):
            for c in range(nb):
                shift = base_matrix[r][c]
                if shift < 0:
                    continue
                for k in range(z):
                    rows.append(r * z + k)
                    cols.append(c * z + (k + shift) % z)

        data = np.ones(len(rows), dtype=np.int8)
        H = sp.csc_matrix((data, (rows, cols)), shape=(M, N), dtype=np.int8)
        return cls(H, mb, nb, z, base_matrix=base_matrix)

    # -----------------------------------------------------------------------
    # Format B: ATSC 3.0 accumulator address table (stub for future use)
    # -----------------------------------------------------------------------
    @classmethod
    def from_atsc3_table(cls, accum_table: list[list[int]], q: int,
                         n: int, k: int, code_type: str = "B") -> QcLdpcCode:
        """Construct from ATSC 3.0 accumulator address table.

        For Type B (IRA): single accumulator with parameter q.
        For Type A (MET): would need q1, q2, m1, m2 (future extension).
        """
        M = n - k
        # Build H from the accumulator table
        # The table defines connections between information bits and parity bits.
        # Each row i of the table has addresses where info bit groups connect.
        rows: list[int] = []
        cols: list[int] = []

        num_info_groups = len(accum_table)
        if code_type == "B":
            for i in range(num_info_groups):
                addrs = accum_table[i]
                for addr in addrs:
                    for j in range(q):
                        parity_idx = (addr + j * q) % M
                        info_idx = i + j * num_info_groups
                        if info_idx < k:
                            # Connection: check node parity_idx sees variable node info_idx
                            rows.append(parity_idx)
                            cols.append(info_idx)

            # Add IRA accumulator structure: parity bits form a staircase
            # p[0] stands alone, p[j] connects to check j and j-1
            for j in range(M):
                rows.append(j)
                cols.append(k + j)
            for j in range(1, M):
                rows.append(j)
                cols.append(k + j - 1)
        else:
            raise NotImplementedError("Type A (MET) not yet implemented")

        data = np.ones(len(rows), dtype=np.int8)
        H = sp.csc_matrix((data, (rows, cols)), shape=(M, n), dtype=np.int8)
        # Deduplicate: ensure binary (clip to 1)
        H.data = np.clip(H.data, 0, 1).astype(np.int8)
        H.eliminate_zeros()

        return cls(H, mb=M, nb=n, z=1, base_matrix=None)

    # -----------------------------------------------------------------------
    # Tanner graph extraction
    # -----------------------------------------------------------------------
    def _build_tanner_graph(self):
        """Extract adjacency lists and edge cross-reference maps from H."""
        H_coo = self.H.tocoo()
        M, N = self.M, self.N

        # cn_to_vn[c] = sorted list of variable nodes connected to check c
        cn_to_vn: list[list[int]] = [[] for _ in range(M)]
        vn_to_cn: list[list[int]] = [[] for _ in range(N)]

        for r, c in zip(H_coo.row, H_coo.col):
            cn_to_vn[r].append(c)
            vn_to_cn[c].append(r)

        # Sort for deterministic ordering
        for c in range(M):
            cn_to_vn[c] = sorted(set(cn_to_vn[c]))
        for v in range(N):
            vn_to_cn[v] = sorted(set(vn_to_cn[v]))

        self.cn_to_vn = cn_to_vn
        self.vn_to_cn = vn_to_cn

        # Edge cross-reference maps: for each (c, v) edge, store the index
        # within both cn_to_vn[c] and vn_to_cn[v]
        # cn_edge_map[(c,v)] = (idx_in_cn_list, idx_in_vn_list)
        cn_edge_map: dict[tuple[int, int], tuple[int, int]] = {}
        for c in range(M):
            for j, v in enumerate(cn_to_vn[c]):
                i = vn_to_cn[v].index(c)
                cn_edge_map[(c, v)] = (j, i)

        self.cn_edge_map = cn_edge_map

        # Degree distributions
        self.cn_degrees = [len(cn_to_vn[c]) for c in range(M)]
        self.vn_degrees = [len(vn_to_cn[v]) for v in range(N)]
        self.num_edges = sum(self.cn_degrees)

    # -----------------------------------------------------------------------
    # Utilities
    # -----------------------------------------------------------------------
    def check_rank(self) -> int:
        """Compute rank of H over GF(2) using dense conversion (small codes only)."""
        H_dense = self.H.toarray().astype(np.int64)
        # Gaussian elimination over GF(2)
        M, N = H_dense.shape
        mat = H_dense.copy()
        rank = 0
        pivot_col = 0
        for row in range(M):
            if pivot_col >= N:
                break
            # Find pivot
            found = False
            for r in range(row, M):
                if mat[r, pivot_col] == 1:
                    mat[[row, r]] = mat[[r, row]]
                    found = True
                    break
            if not found:
                pivot_col += 1
                continue
            # Eliminate
            for r in range(M):
                if r != row and mat[r, pivot_col] == 1:
                    mat[r] = (mat[r] + mat[row]) % 2
            rank += 1
            pivot_col += 1
        return rank

    def verify_consistency(self) -> bool:
        """Verify Tanner graph consistency."""
        # Bidirectional check
        for c in range(self.M):
            for v in self.cn_to_vn[c]:
                if c not in self.vn_to_cn[v]:
                    return False
        for v in range(self.N):
            for c in self.vn_to_cn[v]:
                if v not in self.cn_to_vn[c]:
                    return False
        # Edge count consistency
        cn_edges = sum(len(self.cn_to_vn[c]) for c in range(self.M))
        vn_edges = sum(len(self.vn_to_cn[v]) for v in range(self.N))
        if cn_edges != vn_edges:
            return False
        return True


def make_wifi_code() -> QcLdpcCode:
    """Create the IEEE 802.11n rate-1/2 N=648 Z=27 mock code."""
    return QcLdpcCode.from_base_matrix(WIFI_R12_648_BASE, WIFI_R12_648_Z)


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    print("=== P1: QC-LDPC Code Definition Tests ===\n")
    code = make_wifi_code()

    # Shape checks
    assert code.mb == 12
    assert code.nb == 24
    assert code.z == 27
    assert code.M == 12 * 27  # 324
    assert code.N == 24 * 27  # 648
    assert code.K == 12 * 27  # 324
    print(f"H shape: {code.H.shape} (M={code.M}, N={code.N}, K={code.K})")
    print(f"Rate: {code.rate:.4f}")

    # Row/col weight distributions
    row_weights = np.array(code.cn_degrees)
    col_weights = np.array(code.vn_degrees)
    print(f"Row weights: min={row_weights.min()}, max={row_weights.max()}, "
          f"mean={row_weights.mean():.2f}")
    print(f"Col weights: min={col_weights.min()}, max={col_weights.max()}, "
          f"mean={col_weights.mean():.2f}")

    # Row weights should be reasonable (802.11n has degree 6-8 check nodes)
    assert row_weights.min() >= 3, f"Min row weight too low: {row_weights.min()}"
    assert row_weights.max() <= 20, f"Max row weight too high: {row_weights.max()}"

    # Col weights: info bits have higher degree, parity bits have degree ~2-3
    assert col_weights.min() >= 1, f"Min col weight too low: {col_weights.min()}"

    # Edge count
    print(f"Total edges: {code.num_edges}")
    assert code.num_edges == code.H.nnz

    # Consistency
    assert code.verify_consistency(), "Tanner graph consistency check FAILED"
    print("Tanner graph consistency: PASS")

    # Rank (small enough to check)
    rank = code.check_rank()
    print(f"Rank of H over GF(2): {rank} (M={code.M})")
    # Rank should be close to M (may be slightly less due to dependent rows)
    assert rank >= code.M - code.z, f"Rank too low: {rank}"

    # IRA structure check: parity submatrix H[:, K:] should have staircase-like structure
    H_parity = code.H[:, code.K:].toarray()
    # Each parity column should have weight >= 1
    parity_col_weights = H_parity.sum(axis=0)
    assert np.all(parity_col_weights >= 1), "Parity columns with zero weight"
    print(f"Parity col weights: min={parity_col_weights.min()}, max={parity_col_weights.max()}")

    print("\n=== All P1 tests PASSED ===")

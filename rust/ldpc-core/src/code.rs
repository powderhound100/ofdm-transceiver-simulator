//! QC-LDPC code definition and Tanner graph construction.
//!
//! Supports loading from a base matrix (JSON or in-memory) and expanding
//! QC blocks into a full Tanner graph with CSR adjacency and edge cross-references.

use serde::Deserialize;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

// ---------------------------------------------------------------------------
// Data structures
// ---------------------------------------------------------------------------

/// QC-LDPC code parameters.
#[derive(Debug, Clone)]
pub struct LdpcCode {
    /// Total codeword length N = nb * z
    pub n: usize,
    /// Information bits K = N - M
    pub k: usize,
    /// Number of parity checks M = mb * z
    pub m: usize,
    /// Lifting factor (circulant size)
    pub z: usize,
    /// Base matrix rows
    pub mb: usize,
    /// Base matrix columns
    pub nb: usize,
    /// Base matrix entries in row-major order (mb * nb), -1 = no edge
    pub base_matrix: Vec<i16>,
}

/// Tanner graph in CSR (compressed sparse row) format with edge cross-references.
#[derive(Debug, Clone)]
pub struct TannerGraph {
    /// CSR row pointers for check-node to variable-node adjacency, length m+1
    pub cn_to_vn_ptr: Vec<usize>,
    /// CSR column indices for check-node to variable-node adjacency
    pub cn_to_vn_idx: Vec<usize>,
    /// CSR row pointers for variable-node to check-node adjacency, length n+1
    pub vn_to_cn_ptr: Vec<usize>,
    /// CSR column indices for variable-node to check-node adjacency
    pub vn_to_cn_idx: Vec<usize>,
    /// For cn-side edge i, gives the corresponding vn-side edge index
    pub cn_edge_to_vn_edge: Vec<usize>,
    /// For vn-side edge i, gives the corresponding cn-side edge index
    pub vn_edge_to_cn_edge: Vec<usize>,
    /// Total number of edges in the graph
    pub num_edges: usize,
}

// ---------------------------------------------------------------------------
// JSON deserialization helpers
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
struct BaseMatrixJson {
    mb: usize,
    nb: usize,
    z: usize,
    entries: Vec<Vec<i64>>,
}

#[derive(Deserialize)]
struct TannerGraphJson {
    cn_to_vn: Vec<Vec<usize>>,
    vn_to_cn: Vec<Vec<usize>>,
}

// ---------------------------------------------------------------------------
// LdpcCode constructors
// ---------------------------------------------------------------------------

impl LdpcCode {
    /// Construct from a flat base matrix slice (row-major, mb rows x nb cols).
    pub fn from_base_matrix(base: &[i16], mb: usize, nb: usize, z: usize) -> Self {
        assert_eq!(base.len(), mb * nb, "base matrix size mismatch");
        LdpcCode {
            n: nb * z,
            k: (nb - mb) * z,
            m: mb * z,
            z,
            mb,
            nb,
            base_matrix: base.to_vec(),
        }
    }

    /// Construct from a base_matrix.json file.
    pub fn from_json(path: &str) -> Self {
        let data = fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("Failed to read {}: {}", path, e));
        let bm: BaseMatrixJson = serde_json::from_str(&data)
            .unwrap_or_else(|e| panic!("Failed to parse {}: {}", path, e));

        let mb = bm.mb;
        let nb = bm.nb;
        let z = bm.z;

        let mut base_flat = Vec::with_capacity(mb * nb);
        for row in &bm.entries {
            assert_eq!(row.len(), nb, "row length mismatch in base matrix JSON");
            for &val in row {
                base_flat.push(val as i16);
            }
        }

        Self::from_base_matrix(&base_flat, mb, nb, z)
    }

    /// Build the Tanner graph by expanding QC circulant blocks from the base matrix.
    pub fn build_tanner_graph(&self) -> TannerGraph {
        let mb = self.mb;
        let nb = self.nb;
        let z = self.z;
        let m = self.m;
        let n = self.n;

        // Step 1: Build adjacency lists (matching Python's sorted/deduped approach)
        let mut cn_to_vn_lists: Vec<Vec<usize>> = vec![Vec::new(); m];
        let mut vn_to_cn_lists: Vec<Vec<usize>> = vec![Vec::new(); n];

        for r in 0..mb {
            for c in 0..nb {
                let shift = self.base_matrix[r * nb + c];
                if shift < 0 {
                    continue;
                }
                let shift = shift as usize;
                for k in 0..z {
                    let cn = r * z + k;
                    let vn = c * z + (k + shift) % z;
                    cn_to_vn_lists[cn].push(vn);
                    vn_to_cn_lists[vn].push(cn);
                }
            }
        }

        // Sort and deduplicate (matching Python)
        for list in cn_to_vn_lists.iter_mut() {
            list.sort_unstable();
            list.dedup();
        }
        for list in vn_to_cn_lists.iter_mut() {
            list.sort_unstable();
            list.dedup();
        }

        // Count edges
        let num_edges: usize = cn_to_vn_lists.iter().map(|l| l.len()).sum();

        // Step 2: Build CSR representation
        // cn_to_vn CSR
        let mut cn_to_vn_ptr = Vec::with_capacity(m + 1);
        let mut cn_to_vn_idx = Vec::with_capacity(num_edges);
        let mut ptr = 0;
        for c in 0..m {
            cn_to_vn_ptr.push(ptr);
            for &v in &cn_to_vn_lists[c] {
                cn_to_vn_idx.push(v);
            }
            ptr += cn_to_vn_lists[c].len();
        }
        cn_to_vn_ptr.push(ptr);

        // vn_to_cn CSR
        let mut vn_to_cn_ptr = Vec::with_capacity(n + 1);
        let mut vn_to_cn_idx = Vec::with_capacity(num_edges);
        ptr = 0;
        for v in 0..n {
            vn_to_cn_ptr.push(ptr);
            for &c in &vn_to_cn_lists[v] {
                vn_to_cn_idx.push(c);
            }
            ptr += vn_to_cn_lists[v].len();
        }
        vn_to_cn_ptr.push(ptr);

        // Step 3: Build edge cross-references
        // For each cn-side edge (c, j) where cn_to_vn_lists[c][j] = v,
        // find the index i such that vn_to_cn_lists[v][i] = c.
        // cn_edge_to_vn_edge maps cn-side edge index to vn-side edge index.

        // First, build a map from (v, c) -> vn-side edge index
        let mut vn_edge_map: HashMap<(usize, usize), usize> = HashMap::with_capacity(num_edges);
        for v in 0..n {
            let start = vn_to_cn_ptr[v];
            for (i, &c) in vn_to_cn_lists[v].iter().enumerate() {
                vn_edge_map.insert((v, c), start + i);
            }
        }

        // Similarly, build (c, v) -> cn-side edge index
        let mut cn_edge_map: HashMap<(usize, usize), usize> = HashMap::with_capacity(num_edges);
        for c in 0..m {
            let start = cn_to_vn_ptr[c];
            for (j, &v) in cn_to_vn_lists[c].iter().enumerate() {
                cn_edge_map.insert((c, v), start + j);
            }
        }

        let mut cn_edge_to_vn_edge = vec![0usize; num_edges];
        let mut vn_edge_to_cn_edge = vec![0usize; num_edges];

        for c in 0..m {
            let start = cn_to_vn_ptr[c];
            for (j, &v) in cn_to_vn_lists[c].iter().enumerate() {
                let cn_eidx = start + j;
                let vn_eidx = vn_edge_map[&(v, c)];
                cn_edge_to_vn_edge[cn_eidx] = vn_eidx;
                vn_edge_to_cn_edge[vn_eidx] = cn_eidx;
            }
        }

        TannerGraph {
            cn_to_vn_ptr,
            cn_to_vn_idx,
            vn_to_cn_ptr,
            vn_to_cn_idx,
            cn_edge_to_vn_edge,
            vn_edge_to_cn_edge,
            num_edges,
        }
    }

    /// Build a Tanner graph from a tanner_graph.json file directly.
    /// This is useful for exact comparison with the Python-generated graph.
    pub fn build_tanner_graph_from_json(path: &str) -> TannerGraph {
        let data = fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("Failed to read {}: {}", path, e));
        let tg: TannerGraphJson = serde_json::from_str(&data)
            .unwrap_or_else(|e| panic!("Failed to parse {}: {}", path, e));

        let m = tg.cn_to_vn.len();
        let n = tg.vn_to_cn.len();

        let num_edges: usize = tg.cn_to_vn.iter().map(|l| l.len()).sum();

        // Build CSR for cn_to_vn
        let mut cn_to_vn_ptr = Vec::with_capacity(m + 1);
        let mut cn_to_vn_idx = Vec::with_capacity(num_edges);
        let mut ptr = 0;
        for c in 0..m {
            cn_to_vn_ptr.push(ptr);
            for &v in &tg.cn_to_vn[c] {
                cn_to_vn_idx.push(v);
            }
            ptr += tg.cn_to_vn[c].len();
        }
        cn_to_vn_ptr.push(ptr);

        // Build CSR for vn_to_cn
        let mut vn_to_cn_ptr = Vec::with_capacity(n + 1);
        let mut vn_to_cn_idx = Vec::with_capacity(num_edges);
        ptr = 0;
        for v in 0..n {
            vn_to_cn_ptr.push(ptr);
            for &c in &tg.vn_to_cn[v] {
                vn_to_cn_idx.push(c);
            }
            ptr += tg.vn_to_cn[v].len();
        }
        vn_to_cn_ptr.push(ptr);

        // Build edge cross-references
        let mut vn_edge_map: HashMap<(usize, usize), usize> = HashMap::with_capacity(num_edges);
        for v in 0..n {
            let start = vn_to_cn_ptr[v];
            for (i, &c) in tg.vn_to_cn[v].iter().enumerate() {
                vn_edge_map.insert((v, c), start + i);
            }
        }

        let mut cn_edge_to_vn_edge = vec![0usize; num_edges];
        let mut vn_edge_to_cn_edge = vec![0usize; num_edges];

        for c in 0..m {
            let start = cn_to_vn_ptr[c];
            for (j, &v) in tg.cn_to_vn[c].iter().enumerate() {
                let cn_eidx = start + j;
                let vn_eidx = vn_edge_map[&(v, c)];
                cn_edge_to_vn_edge[cn_eidx] = vn_eidx;
                vn_edge_to_cn_edge[vn_eidx] = cn_eidx;
            }
        }

        TannerGraph {
            cn_to_vn_ptr,
            cn_to_vn_idx,
            vn_to_cn_ptr,
            vn_to_cn_idx,
            cn_edge_to_vn_edge,
            vn_edge_to_cn_edge,
            num_edges,
        }
    }
}

impl TannerGraph {
    /// Degree of check node c (number of variable nodes connected to c).
    #[inline]
    pub fn cn_degree(&self, c: usize) -> usize {
        self.cn_to_vn_ptr[c + 1] - self.cn_to_vn_ptr[c]
    }

    /// Degree of variable node v (number of check nodes connected to v).
    #[inline]
    pub fn vn_degree(&self, v: usize) -> usize {
        self.vn_to_cn_ptr[v + 1] - self.vn_to_cn_ptr[v]
    }

    /// Iterator over variable nodes connected to check node c.
    #[inline]
    pub fn cn_neighbors(&self, c: usize) -> &[usize] {
        &self.cn_to_vn_idx[self.cn_to_vn_ptr[c]..self.cn_to_vn_ptr[c + 1]]
    }

    /// Iterator over check nodes connected to variable node v.
    #[inline]
    pub fn vn_neighbors(&self, v: usize) -> &[usize] {
        &self.vn_to_cn_idx[self.vn_to_cn_ptr[v]..self.vn_to_cn_ptr[v + 1]]
    }

    /// Get the cn-side edge indices for all edges of check node c.
    #[inline]
    pub fn cn_edge_range(&self, c: usize) -> std::ops::Range<usize> {
        self.cn_to_vn_ptr[c]..self.cn_to_vn_ptr[c + 1]
    }

    /// Get the vn-side edge indices for all edges of variable node v.
    #[inline]
    pub fn vn_edge_range(&self, v: usize) -> std::ops::Range<usize> {
        self.vn_to_cn_ptr[v]..self.vn_to_cn_ptr[v + 1]
    }
}

/// Find the test_vectors directory relative to a starting path.
/// Checks common relative paths from within the Rust workspace.
pub fn find_test_vectors_dir() -> Option<String> {
    let candidates = [
        "../../test_vectors",
        "../test_vectors",
        "test_vectors",
        "../../../test_vectors",
        "D:/TV OFDM/test_vectors",
    ];
    for candidate in &candidates {
        if Path::new(candidate).exists() {
            return Some(candidate.to_string());
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;

    fn get_test_vectors_dir() -> String {
        // Try multiple paths since tests can run from different working directories
        let candidates = [
            "../../test_vectors",
            "../test_vectors",
            "test_vectors",
            "../../../test_vectors",
            "D:/TV OFDM/test_vectors",
        ];
        for candidate in &candidates {
            if Path::new(candidate).exists() {
                return candidate.to_string();
            }
        }
        panic!(
            "Could not find test_vectors directory. Tried: {:?}",
            candidates
        );
    }

    #[test]
    fn test_code_from_json() {
        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let code = LdpcCode::from_json(&bm_path);

        assert_eq!(code.mb, 12);
        assert_eq!(code.nb, 24);
        assert_eq!(code.z, 27);
        assert_eq!(code.n, 648);
        assert_eq!(code.k, 324);
        assert_eq!(code.m, 324);
    }

    #[test]
    fn test_graph_construction_matches_json() {
        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let tg_path = format!("{}/tanner_graph.json", tv_dir);

        let code = LdpcCode::from_json(&bm_path);
        let graph_built = code.build_tanner_graph();
        let graph_json = LdpcCode::build_tanner_graph_from_json(&tg_path);

        // Compare cn_to_vn
        assert_eq!(graph_built.cn_to_vn_ptr, graph_json.cn_to_vn_ptr,
                   "cn_to_vn_ptr mismatch");
        assert_eq!(graph_built.cn_to_vn_idx, graph_json.cn_to_vn_idx,
                   "cn_to_vn_idx mismatch");

        // Compare vn_to_cn
        assert_eq!(graph_built.vn_to_cn_ptr, graph_json.vn_to_cn_ptr,
                   "vn_to_cn_ptr mismatch");
        assert_eq!(graph_built.vn_to_cn_idx, graph_json.vn_to_cn_idx,
                   "vn_to_cn_idx mismatch");

        // Compare edge cross-references
        assert_eq!(graph_built.cn_edge_to_vn_edge, graph_json.cn_edge_to_vn_edge,
                   "cn_edge_to_vn_edge mismatch");
        assert_eq!(graph_built.vn_edge_to_cn_edge, graph_json.vn_edge_to_cn_edge,
                   "vn_edge_to_cn_edge mismatch");

        assert_eq!(graph_built.num_edges, graph_json.num_edges);
    }

    #[test]
    fn test_graph_edge_count() {
        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let code = LdpcCode::from_json(&bm_path);
        let graph = code.build_tanner_graph();

        // Count edges from CN side should equal count from VN side
        let cn_edges: usize = (0..code.m).map(|c| graph.cn_degree(c)).sum();
        let vn_edges: usize = (0..code.n).map(|v| graph.vn_degree(v)).sum();
        assert_eq!(cn_edges, vn_edges);
        assert_eq!(cn_edges, graph.num_edges);
    }

    #[test]
    fn test_graph_bidirectional_consistency() {
        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let code = LdpcCode::from_json(&bm_path);
        let graph = code.build_tanner_graph();

        // For every cn->vn edge, verify the reverse exists
        for c in 0..code.m {
            for &v in graph.cn_neighbors(c) {
                let vn_neighbors = graph.vn_neighbors(v);
                assert!(
                    vn_neighbors.contains(&c),
                    "CN {} -> VN {} but VN {} does not list CN {}",
                    c, v, v, c
                );
            }
        }

        // For every vn->cn edge, verify the reverse exists
        for v in 0..code.n {
            for &c in graph.vn_neighbors(v) {
                let cn_neighbors = graph.cn_neighbors(c);
                assert!(
                    cn_neighbors.contains(&v),
                    "VN {} -> CN {} but CN {} does not list VN {}",
                    v, c, c, v
                );
            }
        }
    }

    #[test]
    fn test_cross_reference_roundtrip() {
        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let code = LdpcCode::from_json(&bm_path);
        let graph = code.build_tanner_graph();

        // For every cn-side edge, going cn->vn->cn should recover the same edge
        for cn_eidx in 0..graph.num_edges {
            let vn_eidx = graph.cn_edge_to_vn_edge[cn_eidx];
            let cn_eidx_back = graph.vn_edge_to_cn_edge[vn_eidx];
            assert_eq!(
                cn_eidx, cn_eidx_back,
                "Cross-reference roundtrip failed at cn_edge {}",
                cn_eidx
            );
        }
    }
}

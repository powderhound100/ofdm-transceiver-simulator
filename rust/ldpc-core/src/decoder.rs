//! Normalized Min-Sum LDPC decoder.
//!
//! Flooding schedule with early termination on zero syndrome.
//! Algorithm matches the Python reference implementation exactly.
//!
//! Internal computations use f64 to match Python's numpy.float64 precision.
//! Channel LLR inputs are accepted as f32 (matching test vector format) and
//! promoted to f64 internally.

use crate::code::{LdpcCode, TannerGraph};

/// Result of a decode operation.
#[derive(Debug, Clone)]
pub struct DecodeResult {
    /// Whether the decoder converged (all parity checks satisfied).
    pub converged: bool,
    /// Number of iterations performed.
    pub iterations: usize,
    /// Decoded codeword bits (length N).
    pub decoded_bits: Vec<u8>,
}

/// Normalized Min-Sum LDPC decoder with flooding schedule.
///
/// Uses f64 arithmetic internally to match Python reference exactly.
pub struct MinSumDecoder {
    /// The Tanner graph.
    graph: TannerGraph,
    /// Code parameters.
    n: usize,
    m: usize,
    /// Normalization factor for min-sum.
    alpha: f64,
    /// Maximum number of decoding iterations.
    max_iter: usize,

    // Pre-allocated work buffers (reused across decode calls)
    /// Check-to-variable messages, indexed by cn-side edge index.
    c2v: Vec<f64>,
    /// Posterior LLR for each variable node.
    vn_sum: Vec<f64>,
    /// Hard decision bits.
    hard_bits: Vec<u8>,
    /// Variable-to-check messages, indexed by vn-side edge index.
    v2c: Vec<f64>,
    /// Channel LLR promoted to f64.
    channel_f64: Vec<f64>,
}

impl MinSumDecoder {
    /// Create a new decoder.
    pub fn new(code: &LdpcCode, graph: TannerGraph, alpha: f32, max_iter: usize) -> Self {
        let n = code.n;
        let m = code.m;
        let num_edges = graph.num_edges;

        MinSumDecoder {
            graph,
            n,
            m,
            alpha: alpha as f64,
            max_iter,
            c2v: vec![0.0f64; num_edges],
            vn_sum: vec![0.0f64; n],
            hard_bits: vec![0u8; n],
            v2c: vec![0.0f64; num_edges],
            channel_f64: vec![0.0f64; n],
        }
    }

    /// Decode channel LLRs using normalized min-sum.
    ///
    /// The `channel_llr` slice must have length N (f32, matching test vector format).
    /// Internally promoted to f64 for computation.
    /// Positive LLR means bit 0 is more likely; negative means bit 1.
    pub fn decode(&mut self, channel_llr: &[f32]) -> DecodeResult {
        assert_eq!(channel_llr.len(), self.n, "channel_llr length mismatch");

        let n = self.n;
        let m = self.m;
        let alpha = self.alpha;
        let max_iter = self.max_iter;

        // Promote channel LLR to f64
        for i in 0..n {
            self.channel_f64[i] = channel_llr[i] as f64;
        }

        // Initialize c2v messages to 0
        for val in self.c2v.iter_mut() {
            *val = 0.0;
        }

        for iter in 0..max_iter {
            // ----- Variable Node Update (VNU) -----
            for v in 0..n {
                let vn_start = self.graph.vn_to_cn_ptr[v];
                let vn_end = self.graph.vn_to_cn_ptr[v + 1];

                // Compute posterior (sum of channel LLR + all incoming c2v)
                let mut total = self.channel_f64[v];
                for vn_eidx in vn_start..vn_end {
                    let cn_eidx = self.graph.vn_edge_to_cn_edge[vn_eidx];
                    total += self.c2v[cn_eidx];
                }
                self.vn_sum[v] = total;

                // Compute extrinsic v2c messages
                for vn_eidx in vn_start..vn_end {
                    let cn_eidx = self.graph.vn_edge_to_cn_edge[vn_eidx];
                    self.v2c[vn_eidx] = total - self.c2v[cn_eidx];
                }
            }

            // ----- Hard decision + syndrome check -----
            for v in 0..n {
                self.hard_bits[v] = if self.vn_sum[v] < 0.0 { 1 } else { 0 };
            }

            let mut all_satisfied = true;
            for c in 0..m {
                let mut syndrome_bit = 0u8;
                let cn_start = self.graph.cn_to_vn_ptr[c];
                let cn_end = self.graph.cn_to_vn_ptr[c + 1];
                for idx in cn_start..cn_end {
                    let v = self.graph.cn_to_vn_idx[idx];
                    syndrome_bit ^= self.hard_bits[v];
                }
                if syndrome_bit != 0 {
                    all_satisfied = false;
                    break;
                }
            }

            if all_satisfied {
                return DecodeResult {
                    converged: true,
                    iterations: iter + 1,
                    decoded_bits: self.hard_bits.clone(),
                };
            }

            // ----- Check Node Update (CNU) — Normalized Min-Sum -----
            cnu_scalar(&self.graph, &self.v2c, &mut self.c2v, m, alpha);
        }

        // Did not converge — perform final VNU for hard decision
        for v in 0..n {
            let vn_start = self.graph.vn_to_cn_ptr[v];
            let vn_end = self.graph.vn_to_cn_ptr[v + 1];

            let mut total = self.channel_f64[v];
            for vn_eidx in vn_start..vn_end {
                let cn_eidx = self.graph.vn_edge_to_cn_edge[vn_eidx];
                total += self.c2v[cn_eidx];
            }
            self.hard_bits[v] = if total < 0.0 { 1 } else { 0 };
        }

        DecodeResult {
            converged: false,
            iterations: max_iter,
            decoded_bits: self.hard_bits.clone(),
        }
    }
}

// ---------------------------------------------------------------------------
// Free-standing CNU function (avoids borrow checker issues with &mut self)
// ---------------------------------------------------------------------------

/// Scalar check node update using f64 arithmetic.
fn cnu_scalar(
    graph: &TannerGraph,
    v2c: &[f64],
    c2v: &mut [f64],
    m: usize,
    alpha: f64,
) {
    for c in 0..m {
        let cn_start = graph.cn_to_vn_ptr[c];
        let cn_end = graph.cn_to_vn_ptr[c + 1];
        let degree = cn_end - cn_start;

        if degree < 2 {
            continue;
        }

        // Gather incoming v2c messages for this check node.
        // Compute sign product, min1, min2, argmin1.
        let mut sign_product: f64 = 1.0;
        let mut min1: f64 = f64::MAX;
        let mut min2: f64 = f64::MAX;
        let mut argmin1: usize = 0;

        for j in 0..degree {
            let cn_eidx = cn_start + j;
            let vn_eidx = graph.cn_edge_to_vn_edge[cn_eidx];
            let v2c_val = v2c[vn_eidx];

            let sign = v2c_val.signum();
            let mag = v2c_val.abs();

            sign_product *= sign;

            if mag < min1 {
                min2 = min1;
                min1 = mag;
                argmin1 = j;
            } else if mag < min2 {
                min2 = mag;
            }
        }

        // Compute c2v messages
        for j in 0..degree {
            let cn_eidx = cn_start + j;
            let vn_eidx = graph.cn_edge_to_vn_edge[cn_eidx];
            let v2c_val = v2c[vn_eidx];

            let ext_sign = sign_product * v2c_val.signum();
            let mag = if j == argmin1 { min2 } else { min1 };

            c2v[cn_eidx] = alpha * ext_sign * mag;
        }
    }
}

// ---------------------------------------------------------------------------
// Test vector loading helpers
// ---------------------------------------------------------------------------

/// Load f32 binary file (little-endian) as Vec<f32>.
pub fn load_f32_bin(path: &str) -> Vec<f32> {
    let bytes = std::fs::read(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", path, e));
    assert_eq!(
        bytes.len() % 4,
        0,
        "File size not a multiple of 4: {}",
        path
    );
    let n = bytes.len() / 4;
    let mut result = Vec::with_capacity(n);
    for i in 0..n {
        let b = [bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], bytes[i * 4 + 3]];
        result.push(f32::from_le_bytes(b));
    }
    result
}

/// Load decoded bits binary file (u8, each byte is 0 or 1) as Vec<u8>.
pub fn load_decoded_bin(path: &str) -> Vec<u8> {
    std::fs::read(path).unwrap_or_else(|e| panic!("Failed to read {}: {}", path, e))
}

/// Load number of iterations from text file.
pub fn load_num_iters(path: &str) -> usize {
    let s = std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("Failed to read {}: {}", path, e));
    s.trim().parse().unwrap_or_else(|e| panic!("Failed to parse {}: {}", path, e))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[cfg(test)]
mod tests {
    use super::*;
    use crate::code::LdpcCode;
    use std::path::Path;

    fn get_test_vectors_dir() -> String {
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

    fn setup() -> (MinSumDecoder, String) {
        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let code = LdpcCode::from_json(&bm_path);
        let graph = code.build_tanner_graph();
        let decoder = MinSumDecoder::new(&code, graph, 0.75, 50);
        (decoder, tv_dir)
    }

    #[test]
    fn test_noiseless_convergence_1_iter() {
        let (mut decoder, tv_dir) = setup();
        let llr = load_f32_bin(&format!("{}/llr_snr_noiseless_f32.bin", tv_dir));
        let expected = load_decoded_bin(&format!("{}/decoded_snr_noiseless.bin", tv_dir));
        let expected_iters = load_num_iters(&format!("{}/num_iters_snr_noiseless.txt", tv_dir));

        let result = decoder.decode(&llr);

        assert!(result.converged, "Noiseless should converge");
        assert_eq!(
            result.iterations, expected_iters,
            "Noiseless should converge in {} iteration(s), got {}",
            expected_iters, result.iterations
        );
        assert_eq!(
            result.decoded_bits, expected,
            "Decoded bits do not match test vector"
        );
    }

    #[test]
    fn test_clean_snr_bit_exact() {
        let (mut decoder, tv_dir) = setup();
        let llr = load_f32_bin(&format!("{}/llr_snr_clean_f32.bin", tv_dir));
        let expected = load_decoded_bin(&format!("{}/decoded_snr_clean.bin", tv_dir));
        let expected_iters = load_num_iters(&format!("{}/num_iters_snr_clean.txt", tv_dir));

        let result = decoder.decode(&llr);

        assert_eq!(
            result.decoded_bits, expected,
            "Decoded bits at clean SNR do not match test vector"
        );
        assert_eq!(
            result.iterations, expected_iters,
            "Iteration count at clean SNR: expected {}, got {}",
            expected_iters, result.iterations
        );
    }

    #[test]
    fn test_waterfall_snr_bit_exact() {
        let (mut decoder, tv_dir) = setup();
        let llr = load_f32_bin(&format!("{}/llr_snr_waterfall_f32.bin", tv_dir));
        let expected = load_decoded_bin(&format!("{}/decoded_snr_waterfall.bin", tv_dir));
        let expected_iters = load_num_iters(&format!("{}/num_iters_snr_waterfall.txt", tv_dir));

        let result = decoder.decode(&llr);

        assert_eq!(
            result.decoded_bits, expected,
            "Decoded bits at waterfall SNR do not match test vector"
        );
        assert_eq!(
            result.iterations, expected_iters,
            "Iteration count at waterfall SNR: expected {}, got {}",
            expected_iters, result.iterations
        );
    }

    #[test]
    fn test_high_noise_snr_bit_exact() {
        let (mut decoder, tv_dir) = setup();
        let llr = load_f32_bin(&format!("{}/llr_snr_high_noise_f32.bin", tv_dir));
        let expected = load_decoded_bin(&format!("{}/decoded_snr_high_noise.bin", tv_dir));
        let expected_iters = load_num_iters(&format!("{}/num_iters_snr_high_noise.txt", tv_dir));

        let result = decoder.decode(&llr);

        assert_eq!(
            result.decoded_bits, expected,
            "Decoded bits at high_noise SNR do not match test vector"
        );
        assert_eq!(
            result.iterations, expected_iters,
            "Iteration count at high_noise SNR: expected {}, got {}",
            expected_iters, result.iterations
        );
    }
}

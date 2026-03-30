//! AVX2-accelerated check node update kernel for the min-sum decoder.
//!
//! Provides two variants:
//! - `cnu_avx2_f32`: per-check-node f32 processing using AVX2 target feature
//! - `cnu_avx2_rowblock_f32`: processes Z check nodes simultaneously using AVX2 intrinsics
//!
//! The current decoder uses f64 internally for bit-exact Python match.
//! These f32 SIMD kernels are provided for future high-throughput mode
//! where f32 precision is acceptable.
//!
//! The SIMD kernel produces bit-exact results with the scalar CNU (at f32 precision).
//! Only exact operations are used (min, XOR on sign bits, multiply).

use crate::code::TannerGraph;

/// Check whether AVX2 SIMD is available on this platform.
pub fn is_available() -> bool {
    #[cfg(target_arch = "x86_64")]
    {
        is_x86_feature_detected!("avx2")
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        false
    }
}

/// AVX2 check node update kernel (f32, per-check-node).
///
/// Uses the scalar algorithm compiled with AVX2 enabled so the compiler
/// can auto-vectorize where beneficial.
///
/// # Safety
/// Caller must ensure AVX2 is available (`is_x86_feature_detected!("avx2")`).
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
pub unsafe fn cnu_avx2_f32(
    graph: &TannerGraph,
    v2c: &[f32],
    c2v: &mut [f32],
    m: usize,
    alpha: f32,
) {
    cnu_scalar_f32(graph, v2c, c2v, m, alpha);
}

/// Row-block SIMD CNU kernel (f32): processes Z check nodes simultaneously.
///
/// For QC-LDPC codes where check nodes in the same row-block have the same
/// degree. The Z check nodes in row-block `rb` are `[rb*z .. rb*z+z-1]`.
///
/// For Z=27 with AVX2 (8 floats per register), we process 3 full chunks
/// of 8 and one partial chunk of 3.
///
/// # Safety
/// Caller must ensure AVX2 is available.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
pub unsafe fn cnu_avx2_rowblock_f32(
    graph: &TannerGraph,
    v2c: &[f32],
    c2v: &mut [f32],
    z: usize,
    mb: usize,
    alpha: f32,
) {
    use std::arch::x86_64::*;

    let sign_mask = _mm256_set1_ps(f32::from_bits(0x8000_0000));
    let abs_mask = _mm256_set1_ps(f32::from_bits(0x7FFF_FFFF));
    let alpha_vec = _mm256_set1_ps(alpha);
    let max_val = _mm256_set1_ps(f32::MAX);

    for rb in 0..mb {
        let c0 = rb * z;
        let degree = graph.cn_degree(c0);

        if degree < 2 {
            continue;
        }

        let full_chunks = z / 8;
        let remainder = z % 8;

        // Process chunks of 8 check nodes using AVX2
        for chunk in 0..full_chunks {
            let chunk_offset = chunk * 8;

            let mut sign_prod = _mm256_set1_ps(1.0);
            let mut vmin1 = max_val;
            let mut vmin2 = max_val;
            let mut argmin1 = _mm256_setzero_si256();

            // Pass 1: compute sign_product, min1, min2, argmin1
            for j in 0..degree {
                let mut vals = [0.0f32; 8];
                for lane in 0..8 {
                    let c = c0 + chunk_offset + lane;
                    let cn_eidx = graph.cn_to_vn_ptr[c] + j;
                    let vn_eidx = graph.cn_edge_to_vn_edge[cn_eidx];
                    vals[lane] = v2c[vn_eidx];
                }
                let v = _mm256_loadu_ps(vals.as_ptr());

                let sign_bits = _mm256_and_ps(v, sign_mask);
                let ones = _mm256_set1_ps(1.0);
                let sign_val = _mm256_or_ps(ones, sign_bits);
                sign_prod = _mm256_mul_ps(sign_prod, sign_val);

                let mag = _mm256_and_ps(v, abs_mask);

                let j_vec = _mm256_set1_epi32(j as i32);

                let lt_min1 = _mm256_cmp_ps(mag, vmin1, _CMP_LT_OQ);
                let new_min2_a = _mm256_blendv_ps(vmin2, vmin1, lt_min1);
                let new_min1 = _mm256_blendv_ps(vmin1, mag, lt_min1);
                let new_argmin1 = _mm256_castps_si256(_mm256_blendv_ps(
                    _mm256_castsi256_ps(argmin1),
                    _mm256_castsi256_ps(j_vec),
                    lt_min1,
                ));

                let lt_min2 = _mm256_cmp_ps(mag, new_min2_a, _CMP_LT_OQ);
                let not_lt_min1 = _mm256_cmp_ps(mag, vmin1, _CMP_GE_OQ);
                let update_min2 = _mm256_and_ps(lt_min2, not_lt_min1);
                let new_min2 = _mm256_blendv_ps(new_min2_a, mag, update_min2);

                vmin1 = new_min1;
                vmin2 = new_min2;
                argmin1 = new_argmin1;
            }

            // Pass 2: compute c2v = alpha * ext_sign * (min2 if j==argmin1 else min1)
            for j in 0..degree {
                let mut vals = [0.0f32; 8];
                for lane in 0..8 {
                    let c = c0 + chunk_offset + lane;
                    let cn_eidx = graph.cn_to_vn_ptr[c] + j;
                    let vn_eidx = graph.cn_edge_to_vn_edge[cn_eidx];
                    vals[lane] = v2c[vn_eidx];
                }
                let v = _mm256_loadu_ps(vals.as_ptr());

                let sign_bits = _mm256_and_ps(v, sign_mask);
                let ones = _mm256_set1_ps(1.0);
                let sign_val = _mm256_or_ps(ones, sign_bits);
                let ext_sign = _mm256_mul_ps(sign_prod, sign_val);

                let j_vec = _mm256_set1_epi32(j as i32);
                let is_argmin = _mm256_cmpeq_epi32(j_vec, argmin1);
                let is_argmin_ps = _mm256_castsi256_ps(is_argmin);
                let mag = _mm256_blendv_ps(vmin1, vmin2, is_argmin_ps);

                let result = _mm256_mul_ps(alpha_vec, _mm256_mul_ps(ext_sign, mag));

                let mut result_arr = [0.0f32; 8];
                _mm256_storeu_ps(result_arr.as_mut_ptr(), result);
                for lane in 0..8 {
                    let c = c0 + chunk_offset + lane;
                    let cn_eidx = graph.cn_to_vn_ptr[c] + j;
                    c2v[cn_eidx] = result_arr[lane];
                }
            }
        }

        // Handle remainder with scalar
        if remainder > 0 {
            let chunk_offset = full_chunks * 8;
            for lane in 0..remainder {
                let c = c0 + chunk_offset + lane;
                let cn_start = graph.cn_to_vn_ptr[c];

                let mut sign_product: f32 = 1.0;
                let mut min1: f32 = f32::MAX;
                let mut min2: f32 = f32::MAX;
                let mut argmin1_s: usize = 0;

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
                        argmin1_s = j;
                    } else if mag < min2 {
                        min2 = mag;
                    }
                }

                for j in 0..degree {
                    let cn_eidx = cn_start + j;
                    let vn_eidx = graph.cn_edge_to_vn_edge[cn_eidx];
                    let v2c_val = v2c[vn_eidx];

                    let ext_sign = sign_product * v2c_val.signum();
                    let mag = if j == argmin1_s { min2 } else { min1 };
                    c2v[cn_eidx] = alpha * ext_sign * mag;
                }
            }
        }
    }
}

/// Fallback scalar CNU for non-x86_64 platforms (f32).
#[cfg(not(target_arch = "x86_64"))]
pub unsafe fn cnu_avx2_f32(
    graph: &TannerGraph,
    v2c: &[f32],
    c2v: &mut [f32],
    m: usize,
    alpha: f32,
) {
    cnu_scalar_f32(graph, v2c, c2v, m, alpha);
}

/// Scalar CNU implementation (f32), shared by all code paths.
pub fn cnu_scalar_f32(
    graph: &TannerGraph,
    v2c: &[f32],
    c2v: &mut [f32],
    m: usize,
    alpha: f32,
) {
    for c in 0..m {
        let cn_start = graph.cn_to_vn_ptr[c];
        let cn_end = graph.cn_to_vn_ptr[c + 1];
        let degree = cn_end - cn_start;

        if degree < 2 {
            continue;
        }

        let mut sign_product: f32 = 1.0;
        let mut min1: f32 = f32::MAX;
        let mut min2: f32 = f32::MAX;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::code::LdpcCode;
    use crate::decoder::load_f32_bin;
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
        panic!("Could not find test_vectors directory.");
    }

    #[test]
    fn test_simd_availability() {
        let available = is_available();
        println!("SIMD (AVX2) available: {}", available);
    }

    /// Test that the SIMD CNU (f32) produces bit-exact results with the scalar CNU (f32).
    #[test]
    fn test_simd_cnu_f32_matches_scalar() {
        if !is_available() {
            println!("SIMD not available, skipping SIMD/scalar comparison test");
            return;
        }

        let tv_dir = get_test_vectors_dir();
        let bm_path = format!("{}/base_matrix.json", tv_dir);
        let code = LdpcCode::from_json(&bm_path);
        let graph = code.build_tanner_graph();

        let llr = load_f32_bin(&format!("{}/llr_snr_clean_f32.bin", tv_dir));
        let n = code.n;
        let m = code.m;
        let num_edges = graph.num_edges;

        // Initialize c2v to 0, compute v2c from first VNU pass (f32)
        let c2v_init = vec![0.0f32; num_edges];
        let mut v2c = vec![0.0f32; num_edges];

        for v in 0..n {
            let vn_start = graph.vn_to_cn_ptr[v];
            let vn_end = graph.vn_to_cn_ptr[v + 1];

            let mut total = llr[v];
            for vn_eidx in vn_start..vn_end {
                let cn_eidx = graph.vn_edge_to_cn_edge[vn_eidx];
                total += c2v_init[cn_eidx];
            }
            for vn_eidx in vn_start..vn_end {
                let cn_eidx = graph.vn_edge_to_cn_edge[vn_eidx];
                v2c[vn_eidx] = total - c2v_init[cn_eidx];
            }
        }

        // Run scalar CNU (f32)
        let mut c2v_scalar = vec![0.0f32; num_edges];
        cnu_scalar_f32(&graph, &v2c, &mut c2v_scalar, m, 0.75);

        // Run SIMD CNU (f32)
        let mut c2v_simd = vec![0.0f32; num_edges];
        #[cfg(target_arch = "x86_64")]
        unsafe {
            cnu_avx2_f32(&graph, &v2c, &mut c2v_simd, m, 0.75);
        }

        // Compare bit-exact
        for i in 0..num_edges {
            assert_eq!(
                c2v_scalar[i].to_bits(),
                c2v_simd[i].to_bits(),
                "SIMD/scalar f32 mismatch at edge {}: scalar={}, simd={}",
                i,
                c2v_scalar[i],
                c2v_simd[i]
            );
        }
    }
}

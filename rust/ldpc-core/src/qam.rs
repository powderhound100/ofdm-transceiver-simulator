//! QAM modulation/demodulation: constellation generation, mapping, soft demapping.

/// A QAM constellation with associated bits-per-symbol.
#[derive(Debug, Clone)]
pub struct Constellation {
    pub points: Vec<(f64, f64)>,  // (real, imag) pairs
    pub bps: usize,
}

/// Build a rectangular M-QAM constellation with unit average energy.
/// n_i: number of I levels, n_q: number of Q levels. Total points = n_i * n_q.
pub fn build_rect_qam(n_i: usize, n_q: usize) -> Constellation {
    let mut points = Vec::with_capacity(n_i * n_q);
    let bps = ((n_i * n_q) as f64).log2().round() as usize;

    for q_idx in 0..n_q {
        let q = -(n_q as f64 - 1.0) + 2.0 * q_idx as f64;
        for i_idx in 0..n_i {
            let i = -(n_i as f64 - 1.0) + 2.0 * i_idx as f64;
            points.push((i, q));
        }
    }

    // Normalize to unit average energy
    let e_avg: f64 = points.iter().map(|(i, q)| i * i + q * q).sum::<f64>() / points.len() as f64;
    let scale = 1.0 / e_avg.sqrt();
    for p in &mut points {
        p.0 *= scale;
        p.1 *= scale;
    }

    Constellation { points, bps }
}

/// Get a named constellation.
pub fn get_constellation(name: &str) -> Constellation {
    match name {
        "QPSK" => build_rect_qam(2, 2),
        "16QAM" => build_rect_qam(4, 4),
        "64QAM" => build_rect_qam(8, 8),
        "256QAM" => build_rect_qam(16, 16),
        "512QAM" => build_rect_qam(32, 16),
        "1024QAM" => build_rect_qam(32, 32),
        "2048QAM" => build_rect_qam(64, 32),
        _ => panic!("Unknown constellation: {}", name),
    }
}

/// Map bits to QAM symbols. Returns Vec of (real, imag) pairs.
pub fn qam_map(bits: &[u8], constellation: &Constellation) -> Vec<(f64, f64)> {
    let bps = constellation.bps;
    // Pad bits to multiple of bps
    let mut bits_vec = bits.to_vec();
    let pad = (bps - bits_vec.len() % bps) % bps;
    bits_vec.extend(std::iter::repeat(0u8).take(pad));

    let n_symbols = bits_vec.len() / bps;
    let mut symbols = Vec::with_capacity(n_symbols);

    for s in 0..n_symbols {
        let mut idx = 0usize;
        for k in 0..bps {
            idx += (bits_vec[s * bps + k] as usize) << (bps - 1 - k);
        }
        symbols.push(constellation.points[idx]);
    }
    symbols
}

/// Soft QAM demapping to LLR values (max-log-MAP approximation).
/// Returns Vec of LLR values (positive = bit 0 more likely).
pub fn qam_demap_soft(symbols: &[(f64, f64)], noise_var: f64, constellation: &Constellation) -> Vec<f64> {
    let bps = constellation.bps;
    let nv = if noise_var <= 0.0 { 1e-10 } else { noise_var };
    let n_sym = symbols.len();
    let mut llr = vec![0.0f64; n_sym * bps];

    // General max-log-MAP (used for all modulations including QPSK)
    let pts = &constellation.points;
    let n_pts = pts.len();

    for k in 0..bps {
        let bit_mask = 1usize << (bps - 1 - k);
        // Precompute s0 and s1 sets
        let s0: Vec<(f64, f64)> = (0..n_pts).filter(|&i| (i & bit_mask) == 0).map(|i| pts[i]).collect();
        let s1: Vec<(f64, f64)> = (0..n_pts).filter(|&i| (i & bit_mask) != 0).map(|i| pts[i]).collect();

        for (sym_idx, &(yr, yi)) in symbols.iter().enumerate() {
            let d0 = s0.iter().map(|&(pr, pi)| (yr - pr) * (yr - pr) + (yi - pi) * (yi - pi)).fold(f64::INFINITY, f64::min);
            let d1 = s1.iter().map(|&(pr, pi)| (yr - pr) * (yr - pr) + (yi - pi) * (yi - pi)).fold(f64::INFINITY, f64::min);
            llr[sym_idx * bps + k] = (d1 - d0) / nv;
        }
    }
    llr
}

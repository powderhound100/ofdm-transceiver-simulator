//! OFDM modulation/demodulation with pilot-based channel estimation.

use crate::estimator;

/// OFDM system parameters.
#[derive(Debug, Clone)]
pub struct OfdmParams {
    pub fft_size: usize,
    pub cp_length: usize,
    pub num_data: usize,
    pub num_pilot: usize,
    pub pilot_spacing: usize,
}

impl OfdmParams {
    pub fn default_params() -> Self {
        OfdmParams {
            fft_size: 64,
            cp_length: 16,
            num_data: 48,
            num_pilot: 4,
            pilot_spacing: 12,
        }
    }

    pub fn pilot_indices(&self) -> Vec<usize> {
        let total_used = self.num_data + self.num_pilot;
        let start = (self.fft_size - total_used) / 2;
        let mut indices = Vec::new();
        let mut i = start;
        while i < start + total_used && indices.len() < self.num_pilot {
            indices.push(i);
            i += self.pilot_spacing;
        }
        indices
    }

    pub fn data_indices(&self) -> Vec<usize> {
        let total_used = self.num_data + self.num_pilot;
        let start = (self.fft_size - total_used) / 2;
        let pilots: std::collections::HashSet<usize> = self.pilot_indices().into_iter().collect();
        (start..start + total_used).filter(|i| !pilots.contains(i)).collect()
    }

    pub fn all_used_indices(&self) -> Vec<usize> {
        let total_used = self.num_data + self.num_pilot;
        let start = (self.fft_size - total_used) / 2;
        (start..start + total_used).collect()
    }
}

const PILOT_VALUE: (f64, f64) = (1.0, 0.0);

/// Simple DFT (not FFT) for small sizes — sufficient for N=64.
fn dft(input: &[(f64, f64)], inverse: bool) -> Vec<(f64, f64)> {
    let n = input.len();
    let sign = if inverse { 1.0 } else { -1.0 };
    let scale = if inverse { 1.0 / n as f64 } else { 1.0 };
    let mut output = vec![(0.0, 0.0); n];

    for k in 0..n {
        let mut sum_re = 0.0;
        let mut sum_im = 0.0;
        for j in 0..n {
            let angle = sign * 2.0 * std::f64::consts::PI * (k as f64) * (j as f64) / (n as f64);
            let (sin_a, cos_a) = angle.sin_cos();
            sum_re += input[j].0 * cos_a - input[j].1 * sin_a;
            sum_im += input[j].0 * sin_a + input[j].1 * cos_a;
        }
        output[k] = (sum_re * scale, sum_im * scale);
    }
    output
}

/// OFDM modulate: map QAM symbols to time-domain IQ.
pub fn ofdm_modulate(qam_symbols: &[(f64, f64)], params: &OfdmParams) -> Vec<(f64, f64)> {
    let data_idx = params.data_indices();
    let pilot_idx = params.pilot_indices();
    let n_data = params.num_data;
    let n_ofdm = (qam_symbols.len() + n_data - 1) / n_data;

    // Pad symbols
    let mut padded = qam_symbols.to_vec();
    while padded.len() < n_ofdm * n_data {
        padded.push((0.0, 0.0));
    }

    let mut tx_signal = Vec::new();

    for sym_i in 0..n_ofdm {
        let mut freq = vec![(0.0, 0.0); params.fft_size];

        // Insert data
        for (j, &di) in data_idx.iter().enumerate() {
            if sym_i * n_data + j < padded.len() {
                freq[di] = padded[sym_i * n_data + j];
            }
        }

        // Insert pilots
        for &pi in &pilot_idx {
            freq[pi] = PILOT_VALUE;
        }

        // IFFT
        let time = dft(&freq, true);

        // Add cyclic prefix
        let cp_start = params.fft_size - params.cp_length;
        for i in cp_start..params.fft_size {
            tx_signal.push(time[i]);
        }
        tx_signal.extend_from_slice(&time);
    }

    tx_signal
}

/// OFDM demodulate with selectable estimator and equalizer.
/// Returns (raw_symbols, eq_symbols, channel_estimate, effective_noise_var).
pub fn ofdm_demodulate(
    rx_signal: &[(f64, f64)],
    params: &OfdmParams,
    n_ofdm_symbols: usize,
    estimator: &str,
    equalizer: &str,
    noise_var: f64,
) -> (Vec<(f64, f64)>, Vec<(f64, f64)>, Vec<(f64, f64)>, Vec<f64>) {
    let data_idx = params.data_indices();
    let pilot_idx = params.pilot_indices();
    let all_used_idx = params.all_used_indices();
    let symbol_len = params.fft_size + params.cp_length;

    let mut all_raw = Vec::new();
    let mut all_eq = Vec::new();
    let mut all_h_est = Vec::new();
    let mut all_eff_noise = Vec::new();

    for sym_i in 0..n_ofdm_symbols {
        let start = sym_i * symbol_len;
        let end = start + symbol_len;
        if end > rx_signal.len() {
            break;
        }

        // Remove CP
        let time_domain: Vec<(f64, f64)> = rx_signal[start + params.cp_length..end].to_vec();

        // FFT
        let freq = dft(&time_domain, false);

        // Extract pilots
        let rx_pilots: Vec<(f64, f64)> = pilot_idx.iter().map(|&i| freq[i]).collect();

        // Estimate channel
        let h_est_all = match estimator {
            "LS" => estimator::estimate_ls(&rx_pilots, &pilot_idx, &all_used_idx),
            "LS_improved" => estimator::estimate_ls_improved(&rx_pilots, &pilot_idx, &all_used_idx),
            "LMMSE" => estimator::estimate_lmmse(&rx_pilots, &pilot_idx, &all_used_idx, params.fft_size, noise_var),
            _ => panic!("Unknown estimator: {}", estimator),
        };

        // Map channel estimate to data indices
        let data_in_used: Vec<usize> = data_idx.iter().map(|d| {
            all_used_idx.iter().position(|&u| u == *d).unwrap()
        }).collect();

        let h_at_data: Vec<(f64, f64)> = data_in_used.iter().map(|&i| h_est_all[i]).collect();

        // Extract raw data
        let raw_data: Vec<(f64, f64)> = data_idx.iter().map(|&i| freq[i]).collect();
        all_raw.extend_from_slice(&raw_data);

        // Store channel estimate
        all_h_est.extend(h_est_all.iter().cloned());

        // Equalize
        match equalizer {
            "ZF" => {
                for (j, &(hr, hi)) in h_at_data.iter().enumerate() {
                    let mag = (hr * hr + hi * hi).sqrt();
                    let (hr_s, hi_s) = if mag > 1e-6 { (hr, hi) } else { (1e-6, 0.0) };
                    let denom = hr_s * hr_s + hi_s * hi_s;
                    let (dr, di) = raw_data[j];
                    // Complex division: (dr + j*di) / (hr + j*hi)
                    let eq_re = (dr * hr_s + di * hi_s) / denom;
                    let eq_im = (di * hr_s - dr * hi_s) / denom;
                    all_eq.push((eq_re, eq_im));
                    all_eff_noise.push(noise_var / denom);
                }
            }
            "MMSE" => {
                for (j, &(hr, hi)) in h_at_data.iter().enumerate() {
                    let h_mag_sq = hr * hr + hi * hi;
                    let denom = h_mag_sq + noise_var;
                    let (dr, di) = raw_data[j];
                    // MMSE: h* * y / (|h|^2 + sigma^2)
                    let eq_re = (hr * dr + hi * di) / denom;
                    let eq_im = (hr * di - hi * dr) / denom;
                    all_eq.push((eq_re, eq_im));
                    all_eff_noise.push(noise_var / denom);
                }
            }
            _ => panic!("Unknown equalizer: {}", equalizer),
        }
    }

    (all_raw, all_eq, all_h_est, all_eff_noise)
}

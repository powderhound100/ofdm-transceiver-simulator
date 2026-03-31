//! OFDM timing and frequency synchronization.
//!
//! Implements Schmidl-Cox symbol timing and CP-based CFO estimation.

use std::f64::consts::PI;

/// Complex number type for sync operations.
#[derive(Debug, Clone, Copy)]
pub struct Complex {
    pub re: f64,
    pub im: f64,
}

impl Complex {
    pub fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    pub fn conj(&self) -> Complex {
        Complex { re: self.re, im: -self.im }
    }

    pub fn mul(&self, other: &Complex) -> Complex {
        Complex {
            re: self.re * other.re - self.im * other.im,
            im: self.re * other.im + self.im * other.re,
        }
    }

    pub fn mag_sq(&self) -> f64 {
        self.re * self.re + self.im * self.im
    }

    pub fn angle(&self) -> f64 {
        self.im.atan2(self.re)
    }
}

/// Schmidl-Cox symbol timing synchronization using CP correlation.
///
/// # Arguments
/// * `rx_signal` - Complex received samples
/// * `fft_size` - FFT size N
/// * `cp_length` - Cyclic prefix length
///
/// # Returns
/// Estimated symbol start index
pub fn schmidl_cox_timing(rx_signal: &[Complex], fft_size: usize, cp_length: usize) -> usize {
    let n = fft_size;
    let l = cp_length;

    if rx_signal.len() < n + l {
        return 0;
    }

    let search_range = (rx_signal.len() - n - l).min(2 * (n + l));
    let mut best_metric = 0.0_f64;
    let mut best_idx = 0_usize;

    for start in 0..search_range {
        // P = sum r[n+k] * conj(r[n+k+N]) for k=0..CP_LEN-1
        let mut p = Complex::new(0.0, 0.0);
        let mut r = 0.0_f64;

        for k in 0..l {
            let curr = rx_signal[start + k];
            let delayed = rx_signal[start + k + n];

            let prod = curr.mul(&delayed.conj());
            p.re += prod.re;
            p.im += prod.im;
            r += delayed.mag_sq();
        }

        let metric = if r > 1e-10 {
            p.mag_sq() / (r * r)
        } else {
            0.0
        };

        if metric > best_metric {
            best_metric = metric;
            best_idx = start;
        }
    }

    best_idx
}

/// Estimate fractional CFO from CP correlation.
///
/// CFO = angle(P[n_peak]) / (2 * pi * N)
pub fn estimate_cfo_cp(
    rx_signal: &[Complex],
    symbol_start: usize,
    fft_size: usize,
    cp_length: usize,
) -> f64 {
    let n = fft_size;
    let l = cp_length;

    if symbol_start + n + l > rx_signal.len() {
        return 0.0;
    }

    let mut p = Complex::new(0.0, 0.0);
    for k in 0..l {
        let curr = rx_signal[symbol_start + k];
        let delayed = rx_signal[symbol_start + k + n];
        let prod = curr.mul(&delayed.conj());
        p.re += prod.re;
        p.im += prod.im;
    }

    p.angle() / (2.0 * PI * n as f64)
}

/// Apply CFO correction to received signal.
///
/// r_corrected[n] = r[n] * exp(-j * 2*pi * cfo * n)
pub fn correct_cfo(rx_signal: &[Complex], cfo: f64) -> Vec<Complex> {
    rx_signal
        .iter()
        .enumerate()
        .map(|(n, sample)| {
            let phase = -2.0 * PI * cfo * n as f64;
            let correction = Complex::new(phase.cos(), phase.sin());
            sample.mul(&correction)
        })
        .collect()
}

/// Estimate residual CFO from pilot phase rotation across symbols.
pub fn estimate_fine_cfo_pilots(
    h_pilot_curr: &[Complex],
    h_pilot_prev: &[Complex],
    symbol_duration: f64,
) -> f64 {
    if h_pilot_curr.is_empty() || h_pilot_prev.is_empty() {
        return 0.0;
    }

    let mut sum_phase = 0.0;
    let mut count = 0;

    for (curr, prev) in h_pilot_curr.iter().zip(h_pilot_prev.iter()) {
        if prev.mag_sq() > 1e-20 {
            let ratio = curr.mul(&prev.conj());
            sum_phase += ratio.angle();
            count += 1;
        }
    }

    if count == 0 {
        return 0.0;
    }

    let mean_phase = sum_phase / count as f64;
    mean_phase / (2.0 * PI * symbol_duration)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cfo_correction_identity() {
        // With zero CFO, correction should be identity
        let signal = vec![
            Complex::new(1.0, 0.0),
            Complex::new(0.0, 1.0),
            Complex::new(-1.0, 0.0),
        ];
        let corrected = correct_cfo(&signal, 0.0);

        for (orig, corr) in signal.iter().zip(corrected.iter()) {
            assert!((orig.re - corr.re).abs() < 1e-10);
            assert!((orig.im - corr.im).abs() < 1e-10);
        }
    }

    #[test]
    fn test_timing_with_known_cp() {
        // Create a signal with known CP structure
        let fft_n = 64;
        let cp_len = 16;
        let mut signal = vec![Complex::new(0.0, 0.0); 200];

        // Place an OFDM symbol at position 10
        // Fill FFT portion with random-ish values
        for i in 0..fft_n {
            let val = ((i * 7 + 3) % 20) as f64 / 10.0 - 1.0;
            signal[10 + cp_len + i] = Complex::new(val, val * 0.5);
        }
        // Copy last cp_len samples as CP
        for i in 0..cp_len {
            signal[10 + i] = signal[10 + fft_n + i];
        }

        let detected = schmidl_cox_timing(&signal, fft_n, cp_len);
        // Should detect near position 10
        assert!(
            (detected as i64 - 10).abs() <= 2,
            "Expected timing near 10, got {}",
            detected
        );
    }
}

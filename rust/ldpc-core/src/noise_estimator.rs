//! Pilot-based noise variance estimation.
//!
//! Estimates sigma^2 from pilot subcarriers:
//!   noise[k] = RX_pilot[k] - TX_PILOT * H_est[k]
//!   sigma^2  = mean(|noise[k]|^2)
//!
//! Since TX_PILOT = 1+j0, noise[k] = RX_pilot[k] - H_est[k]

/// Complex number type (re, im)
#[derive(Debug, Clone, Copy)]
pub struct Complex {
    pub re: f64,
    pub im: f64,
}

impl Complex {
    pub fn new(re: f64, im: f64) -> Self {
        Self { re, im }
    }

    pub fn mag_sq(&self) -> f64 {
        self.re * self.re + self.im * self.im
    }

    pub fn sub(&self, other: &Complex) -> Complex {
        Complex {
            re: self.re - other.re,
            im: self.im - other.im,
        }
    }
}

/// Estimate noise variance from pilot subcarriers.
///
/// # Arguments
/// * `rx_pilots` - Received pilot values
/// * `h_est_at_pilots` - Channel estimates at pilot positions
///
/// # Returns
/// Estimated noise variance (f64)
pub fn estimate_noise_variance(rx_pilots: &[Complex], h_est_at_pilots: &[Complex]) -> f64 {
    assert_eq!(rx_pilots.len(), h_est_at_pilots.len());

    if rx_pilots.is_empty() {
        return 1e-10;
    }

    let mut sum_power = 0.0;
    for (rx, h) in rx_pilots.iter().zip(h_est_at_pilots.iter()) {
        // TX_PILOT = 1+j0, so expected = H_est
        let noise = rx.sub(h);
        sum_power += noise.mag_sq();
    }

    let noise_var = sum_power / rx_pilots.len() as f64;
    noise_var.max(1e-10)
}

/// Estimate noise variance with exponential moving average across symbols.
pub fn estimate_noise_variance_ema(
    rx_pilots_list: &[Vec<Complex>],
    h_est_list: &[Vec<Complex>],
    alpha: f64,
) -> f64 {
    if rx_pilots_list.is_empty() {
        return 1e-10;
    }

    let mut sigma2 = estimate_noise_variance(&rx_pilots_list[0], &h_est_list[0]);

    for i in 1..rx_pilots_list.len() {
        let new_est = estimate_noise_variance(&rx_pilots_list[i], &h_est_list[i]);
        sigma2 = (1.0 - alpha) * sigma2 + alpha * new_est;
    }

    sigma2
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_no_noise() {
        let pilots = vec![
            Complex::new(1.0, 0.0),
            Complex::new(0.5, 0.5),
            Complex::new(-1.0, 0.0),
            Complex::new(0.0, -1.0),
        ];
        // If H_est = RX_pilot, noise = 0
        let h_est = pilots.clone();
        let var = estimate_noise_variance(&pilots, &h_est);
        assert!(var < 1e-9, "Expected near-zero noise var, got {}", var);
    }

    #[test]
    fn test_known_noise() {
        let h_est = vec![
            Complex::new(1.0, 0.0),
            Complex::new(1.0, 0.0),
            Complex::new(1.0, 0.0),
            Complex::new(1.0, 0.0),
        ];
        // Add known noise of 0.1 to real part
        let pilots = vec![
            Complex::new(1.1, 0.0),
            Complex::new(1.1, 0.0),
            Complex::new(1.1, 0.0),
            Complex::new(1.1, 0.0),
        ];
        let var = estimate_noise_variance(&pilots, &h_est);
        // Expected: 0.1^2 = 0.01
        assert!((var - 0.01).abs() < 1e-6, "Expected 0.01, got {}", var);
    }
}

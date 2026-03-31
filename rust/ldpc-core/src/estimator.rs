//! Channel estimators: LS, LS-Improved, LMMSE.

/// Linear interpolation helper.
fn interp(x_new: &[f64], x_known: &[f64], y_known: &[f64]) -> Vec<f64> {
    x_new.iter().map(|&xn| {
        if xn <= x_known[0] {
            return y_known[0];
        }
        if xn >= *x_known.last().unwrap() {
            return *y_known.last().unwrap();
        }
        // Find bracketing interval
        let mut idx = 0;
        for i in 0..x_known.len() - 1 {
            if xn >= x_known[i] && xn <= x_known[i + 1] {
                idx = i;
                break;
            }
        }
        let t = (xn - x_known[idx]) / (x_known[idx + 1] - x_known[idx]);
        y_known[idx] + t * (y_known[idx + 1] - y_known[idx])
    }).collect()
}

const PILOT_VALUE: f64 = 1.0;

/// LS estimator with magnitude+phase interpolation (matches original Python).
pub fn estimate_ls(rx_pilots: &[(f64, f64)], pilot_idx: &[usize], all_used_idx: &[usize]) -> Vec<(f64, f64)> {
    // LS at pilots: H = Y / X_pilot
    let h_ls: Vec<(f64, f64)> = rx_pilots.iter().map(|&(r, i)| (r / PILOT_VALUE, i / PILOT_VALUE)).collect();

    let pilot_f: Vec<f64> = pilot_idx.iter().map(|&i| i as f64).collect();
    let all_f: Vec<f64> = all_used_idx.iter().map(|&i| i as f64).collect();

    // Interpolate magnitude and phase separately
    let mags: Vec<f64> = h_ls.iter().map(|(r, i)| (r * r + i * i).sqrt()).collect();
    let phases: Vec<f64> = h_ls.iter().map(|(r, i)| i.atan2(*r)).collect();

    let interp_mag = interp(&all_f, &pilot_f, &mags);
    let interp_phase = interp(&all_f, &pilot_f, &phases);

    interp_mag.iter().zip(interp_phase.iter()).map(|(&m, &p)| {
        (m * p.cos(), m * p.sin())
    }).collect()
}

/// LS-Improved estimator with real/imag interpolation (avoids phase wrapping).
pub fn estimate_ls_improved(rx_pilots: &[(f64, f64)], pilot_idx: &[usize], all_used_idx: &[usize]) -> Vec<(f64, f64)> {
    let h_ls: Vec<(f64, f64)> = rx_pilots.iter().map(|&(r, i)| (r / PILOT_VALUE, i / PILOT_VALUE)).collect();

    let pilot_f: Vec<f64> = pilot_idx.iter().map(|&i| i as f64).collect();
    let all_f: Vec<f64> = all_used_idx.iter().map(|&i| i as f64).collect();

    let reals: Vec<f64> = h_ls.iter().map(|(r, _)| *r).collect();
    let imags: Vec<f64> = h_ls.iter().map(|(_, i)| *i).collect();

    let interp_re = interp(&all_f, &pilot_f, &reals);
    let interp_im = interp(&all_f, &pilot_f, &imags);

    interp_re.iter().zip(interp_im.iter()).map(|(&r, &i)| (r, i)).collect()
}

/// LMMSE estimator with DFT-based Tikhonov regularization.
pub fn estimate_lmmse(
    rx_pilots: &[(f64, f64)],
    pilot_idx: &[usize],
    all_used_idx: &[usize],
    fft_size: usize,
    noise_var: f64,
) -> Vec<(f64, f64)> {
    let h_ls: Vec<(f64, f64)> = rx_pilots.iter().map(|&(r, i)| (r / PILOT_VALUE, i / PILOT_VALUE)).collect();
    let n_p = pilot_idx.len();
    let l = n_p; // max resolvable delay taps
    let fft_f = fft_size as f64;
    let sqrt_fft = fft_f.sqrt();

    // Build F_p: n_p x L DFT matrix at pilot positions
    // F_p[i][j] = exp(-2j*pi*pilot_idx[i]*j/fft_size) / sqrt(fft_size)
    let mut fp_re = vec![vec![0.0; l]; n_p];
    let mut fp_im = vec![vec![0.0; l]; n_p];
    for i in 0..n_p {
        for j in 0..l {
            let angle = -2.0 * std::f64::consts::PI * (pilot_idx[i] as f64) * (j as f64) / fft_f;
            fp_re[i][j] = angle.cos() / sqrt_fft;
            fp_im[i][j] = angle.sin() / sqrt_fft;
        }
    }

    // A = F_p^H @ F_p + lambda * I, where lambda = noise_var * L
    let lam = noise_var * l as f64;
    let mut a_re = vec![vec![0.0; l]; l];
    let mut a_im = vec![vec![0.0; l]; l];
    for i in 0..l {
        for j in 0..l {
            let mut sr = 0.0;
            let mut si = 0.0;
            for k in 0..n_p {
                // F_p^H[i][k] * F_p[k][j] = conj(F_p[k][i]) * F_p[k][j]
                let cr = fp_re[k][i];
                let ci = -fp_im[k][i]; // conjugate
                let br = fp_re[k][j];
                let bi = fp_im[k][j];
                sr += cr * br - ci * bi;
                si += cr * bi + ci * br;
            }
            a_re[i][j] = sr;
            a_im[i][j] = si;
            if i == j {
                a_re[i][j] += lam;
            }
        }
    }

    // b = F_p^H @ h_ls
    let mut b_re = vec![0.0; l];
    let mut b_im = vec![0.0; l];
    for i in 0..l {
        for k in 0..n_p {
            let cr = fp_re[k][i];
            let ci = -fp_im[k][i]; // conjugate
            let (hr, hi) = h_ls[k];
            b_re[i] += cr * hr - ci * hi;
            b_im[i] += cr * hi + ci * hr;
        }
    }

    // Solve A @ h_hat = b using Gaussian elimination with partial pivoting
    let h_hat = solve_complex_system(&a_re, &a_im, &b_re, &b_im, l);

    // F_full: all_used_idx.len() x L
    let n_out = all_used_idx.len();
    let mut result = vec![(0.0, 0.0); n_out];
    for i in 0..n_out {
        let mut sr = 0.0;
        let mut si = 0.0;
        for j in 0..l {
            let angle = -2.0 * std::f64::consts::PI * (all_used_idx[i] as f64) * (j as f64) / fft_f;
            let fr = angle.cos() / sqrt_fft;
            let fi = angle.sin() / sqrt_fft;
            sr += fr * h_hat[j].0 - fi * h_hat[j].1;
            si += fr * h_hat[j].1 + fi * h_hat[j].0;
        }
        result[i] = (sr, si);
    }
    result
}

/// Solve complex linear system Ax = b via Gaussian elimination.
fn solve_complex_system(ar: &[Vec<f64>], ai: &[Vec<f64>], br: &[f64], bi: &[f64], n: usize) -> Vec<(f64, f64)> {
    // Build augmented matrix [A | b]
    let mut mr = vec![vec![0.0; n + 1]; n];
    let mut mi = vec![vec![0.0; n + 1]; n];
    for i in 0..n {
        for j in 0..n {
            mr[i][j] = ar[i][j];
            mi[i][j] = ai[i][j];
        }
        mr[i][n] = br[i];
        mi[i][n] = bi[i];
    }

    // Forward elimination with partial pivoting
    for col in 0..n {
        // Find pivot
        let mut max_mag = 0.0;
        let mut max_row = col;
        for row in col..n {
            let mag = mr[row][col] * mr[row][col] + mi[row][col] * mi[row][col];
            if mag > max_mag {
                max_mag = mag;
                max_row = row;
            }
        }
        mr.swap(col, max_row);
        mi.swap(col, max_row);

        let pr = mr[col][col];
        let pi_val = mi[col][col];
        let p_mag_sq = pr * pr + pi_val * pi_val;
        if p_mag_sq < 1e-30 {
            continue;
        }

        for row in (col + 1)..n {
            // factor = m[row][col] / m[col][col]
            let (fr, fi) = complex_div(mr[row][col], mi[row][col], pr, pi_val);
            for j in col..=n {
                // m[row][j] -= factor * m[col][j]
                let sub_re = fr * mr[col][j] - fi * mi[col][j];
                let sub_im = fr * mi[col][j] + fi * mr[col][j];
                mr[row][j] -= sub_re;
                mi[row][j] -= sub_im;
            }
        }
    }

    // Back substitution
    let mut x = vec![(0.0, 0.0); n];
    for i in (0..n).rev() {
        let mut sr = mr[i][n];
        let mut si = mi[i][n];
        for j in (i + 1)..n {
            let pr = mr[i][j] * x[j].0 - mi[i][j] * x[j].1;
            let pi_val = mr[i][j] * x[j].1 + mi[i][j] * x[j].0;
            sr -= pr;
            si -= pi_val;
        }
        x[i] = complex_div(sr, si, mr[i][i], mi[i][i]);
    }
    x
}

fn complex_div(ar: f64, ai: f64, br: f64, bi: f64) -> (f64, f64) {
    let denom = br * br + bi * bi;
    ((ar * br + ai * bi) / denom, (ai * br - ar * bi) / denom)
}

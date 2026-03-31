//! Channel models: multipath fading + AWGN for complex baseband signals.

use rand::Rng;
use rand_distr::{Distribution, Normal};

/// Channel model definition.
#[derive(Debug, Clone)]
pub struct ChannelModel {
    pub delays: Vec<usize>,
    pub powers_db: Vec<f64>,
    pub description: String,
}

/// Get a named channel model. Matches Python channel_model.py exactly.
pub fn get_channel_model(name: &str) -> ChannelModel {
    match name {
        "flat" => ChannelModel {
            delays: vec![0], powers_db: vec![0.0],
            description: "Flat fading (single tap, AWGN-like)".into(),
        },
        "two_tap" => ChannelModel {
            delays: vec![0, 5], powers_db: vec![0.0, -3.0],
            description: "Two-tap: main path + 5-sample delayed reflection at -3dB".into(),
        },
        "tu6" => ChannelModel {
            delays: vec![0, 1, 3, 5, 8, 12],
            powers_db: vec![-3.0, 0.0, -2.0, -6.0, -8.0, -10.0],
            description: "Typical Urban 6-tap (TU-6)".into(),
        },
        "cost207_ra" => ChannelModel {
            delays: vec![0, 1, 2, 3], powers_db: vec![0.0, -2.0, -10.0, -20.0],
            description: "COST 207 Rural Area".into(),
        },
        "cost207_ht" => ChannelModel {
            delays: vec![0, 2, 4, 7, 11, 17],
            powers_db: vec![0.0, -2.0, -4.0, -7.0, -6.0, -12.0],
            description: "COST 207 Hilly Terrain".into(),
        },
        "brazil_a" => ChannelModel {
            delays: vec![0, 3, 13], powers_db: vec![0.0, -15.0, -20.0],
            description: "Brazil channel A — indoor reception".into(),
        },
        "brazil_b" => ChannelModel {
            delays: vec![0, 1, 3, 11, 57],
            powers_db: vec![0.0, -12.0, -4.0, -7.0, -15.0],
            description: "Brazil channel B — outdoor pedestrian".into(),
        },
        "brazil_c" => ChannelModel {
            delays: vec![0, 1, 2, 5, 11, 17],
            powers_db: vec![0.0, -5.0, -2.0, -6.0, -8.0, -10.0],
            description: "Brazil channel C — vehicular urban".into(),
        },
        "brazil_d" => ChannelModel {
            delays: vec![0, 3, 5, 13, 50, 120],
            powers_db: vec![0.0, -10.0, -3.0, -4.0, -7.0, -15.0],
            description: "Brazil channel D — mountainous / SFN".into(),
        },
        "brazil_e" => ChannelModel {
            delays: vec![0, 1, 3, 10, 25, 138],
            powers_db: vec![0.0, -5.0, -2.0, -6.0, -8.0, -10.0],
            description: "Brazil channel E — SFN equal-power echoes".into(),
        },
        _ => panic!("Unknown channel model: {}", name),
    }
}

/// Create complex channel impulse response with random phase per tap.
pub fn make_channel_taps(model: &ChannelModel, rng: &mut impl Rng) -> Vec<(f64, f64)> {
    let max_delay = *model.delays.iter().max().unwrap_or(&0);
    let mut h = vec![(0.0, 0.0); max_delay + 1];

    for (&d, &p_db) in model.delays.iter().zip(model.powers_db.iter()) {
        let amplitude = 10.0_f64.powf(p_db / 20.0);
        let phase = rng.gen::<f64>() * 2.0 * std::f64::consts::PI;
        h[d] = (amplitude * phase.cos(), amplitude * phase.sin());
    }

    // Normalize to unit energy
    let energy: f64 = h.iter().map(|(r, i)| r * r + i * i).sum();
    let scale = 1.0 / energy.sqrt();
    for p in &mut h {
        p.0 *= scale;
        p.1 *= scale;
    }
    h
}

/// Apply multipath channel via convolution.
pub fn apply_multipath(signal: &[(f64, f64)], taps: &[(f64, f64)]) -> Vec<(f64, f64)> {
    let n = signal.len();
    let mut output = vec![(0.0, 0.0); n];

    for i in 0..n {
        let mut sum_re = 0.0;
        let mut sum_im = 0.0;
        for (j, &(tr, ti)) in taps.iter().enumerate() {
            if i >= j {
                let (sr, si) = signal[i - j];
                // Complex multiply: (sr + j*si) * (tr + j*ti)
                sum_re += sr * tr - si * ti;
                sum_im += sr * ti + si * tr;
            }
        }
        output[i] = (sum_re, sum_im);
    }
    output
}

/// Add AWGN noise to complex signal.
pub fn apply_awgn(signal: &[(f64, f64)], snr_db: f64, rng: &mut impl Rng) -> Vec<(f64, f64)> {
    if snr_db > 100.0 {
        return signal.to_vec();
    }

    let sig_power: f64 = signal.iter().map(|(r, i)| r * r + i * i).sum::<f64>() / signal.len() as f64;
    let snr_linear = 10.0_f64.powf(snr_db / 10.0);
    let noise_power = sig_power / snr_linear;
    let noise_std = (noise_power / 2.0).sqrt();

    let normal = Normal::new(0.0, noise_std).unwrap();
    signal.iter().map(|&(r, i)| {
        (r + normal.sample(rng), i + normal.sample(rng))
    }).collect()
}

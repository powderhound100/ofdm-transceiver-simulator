//! LDPC decoder CLI — test vector validation, BER sweep, and full OFDM chain sweep.
//!
//! Usage:
//!   ldpc-cli                        # default: test vectors + BPSK sweep
//!   ldpc-cli --ofdm-sweep           # full OFDM chain BER sweep
//!   ldpc-cli --ofdm-sweep --output results.json --snr-min -10 --snr-max 20

use clap::Parser;
use ldpc_core::code::LdpcCode;
use ldpc_core::decoder::{load_decoded_bin, load_f32_bin, load_num_iters, MinSumDecoder};
use ldpc_core::qam::{get_constellation, qam_demap_soft, qam_map};
use ldpc_core::ofdm::{ofdm_demodulate, ofdm_modulate, OfdmParams};
use ldpc_core::channel::{apply_awgn, apply_multipath, get_channel_model, make_channel_taps};

use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use rand_distr::{Distribution, Normal};

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::time::Instant;

#[derive(Parser)]
#[command(name = "ldpc-cli", about = "LDPC decoder CLI with OFDM chain support")]
struct Args {
    #[arg(long, help = "Path to test_vectors directory")]
    test_vectors: Option<String>,

    #[arg(long, help = "Run BPSK BER sweep")]
    ber_sweep: bool,

    #[arg(long, help = "Run full OFDM chain BER sweep")]
    ofdm_sweep: bool,

    #[arg(long, default_value = "rust_ber_sweep_data.json", help = "Output JSON file")]
    output: String,

    #[arg(long, help = "Modulation filter (e.g. QPSK,16QAM,64QAM)")]
    modulation: Option<String>,

    #[arg(long, help = "Channel filter (e.g. flat,two_tap,tu6)")]
    channel: Option<String>,

    #[arg(long, help = "Estimator filter (e.g. LS,LS_improved,LMMSE)")]
    estimator: Option<String>,

    #[arg(long, default_value_t = -40.0, help = "Minimum SNR in dB")]
    snr_min: f64,

    #[arg(long, default_value_t = 30.0, help = "Maximum SNR in dB")]
    snr_max: f64,
}

fn find_test_vectors_dir() -> String {
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

/// BPSK modulate: 0 -> +1.0, 1 -> -1.0
fn bpsk_modulate(bits: &[u8]) -> Vec<f32> {
    bits.iter().map(|&b| 1.0 - 2.0 * b as f32).collect()
}

/// Compute noise variance: sigma^2 = 1 / (2 * R * 10^(snr_db/10))
fn compute_sigma2(code_rate: f32, snr_db: f32) -> f32 {
    let snr_linear = 10.0f32.powf(snr_db / 10.0);
    1.0 / (2.0 * code_rate * snr_linear)
}

/// Compute LLR = 2 * received / sigma^2
fn compute_llr(received: &[f32], sigma2: f32) -> Vec<f32> {
    if sigma2 == 0.0 {
        return received.iter().map(|&r| r.signum() * 1000.0).collect();
    }
    let scale = 2.0 / sigma2;
    received.iter().map(|&r| r * scale).collect()
}

/// Generate a random codeword (all-zero codeword for BER testing — valid for any linear code).
fn all_zero_codeword(n: usize) -> Vec<u8> {
    vec![0u8; n]
}

// ---------------------------------------------------------------------------
// GF(2) encoder for OFDM chain (needs random info bits, not all-zero)
// ---------------------------------------------------------------------------

/// Build full parity-check matrix H from QC-LDPC base matrix.
/// Returns H as a flat row-major bit matrix (M x N), stored as Vec<Vec<u8>>.
fn build_parity_check_matrix(code: &LdpcCode) -> Vec<Vec<u8>> {
    let mb = code.mb;
    let nb = code.nb;
    let z = code.z;
    let m = code.m;
    let n = code.n;

    let mut h = vec![vec![0u8; n]; m];

    for r in 0..mb {
        for c in 0..nb {
            let shift = code.base_matrix[r * nb + c];
            if shift < 0 {
                continue;
            }
            let shift = shift as usize;
            for k in 0..z {
                let row = r * z + k;
                let col = c * z + (k + shift) % z;
                h[row][col] = 1;
            }
        }
    }
    h
}

/// Compute GF(2) inverse of a square matrix. Returns None if singular.
fn gf2_inverse(mat: &[Vec<u8>]) -> Option<Vec<Vec<u8>>> {
    let m = mat.len();
    // Build augmented matrix [A | I]
    let mut aug: Vec<Vec<u8>> = vec![vec![0u8; 2 * m]; m];
    for i in 0..m {
        for j in 0..m {
            aug[i][j] = mat[i][j];
        }
        aug[i][m + i] = 1;
    }

    for col in 0..m {
        // Find pivot
        let mut found = None;
        for row in col..m {
            if aug[row][col] == 1 {
                found = Some(row);
                break;
            }
        }
        let pivot = found?;
        aug.swap(col, pivot);

        // Eliminate
        for row in 0..m {
            if row != col && aug[row][col] == 1 {
                for j in 0..(2 * m) {
                    aug[row][j] ^= aug[col][j];
                }
            }
        }
    }

    // Extract inverse from right half
    let inv: Vec<Vec<u8>> = aug.iter().map(|row| row[m..].to_vec()).collect();
    Some(inv)
}

/// Pre-computed encoder for GF(2) LDPC encoding.
struct LdpcEncoder {
    k: usize,
    n: usize,
    h_info: Vec<Vec<u8>>,       // M x K
    h_parity_inv: Vec<Vec<u8>>, // M x M
}

impl LdpcEncoder {
    fn new(code: &LdpcCode) -> Self {
        let h = build_parity_check_matrix(code);
        let k = code.k;

        // H_info = H[:, :K]
        let h_info: Vec<Vec<u8>> = h.iter().map(|row| row[..k].to_vec()).collect();

        // H_parity = H[:, K:]
        let h_parity: Vec<Vec<u8>> = h.iter().map(|row| row[k..].to_vec()).collect();

        let h_parity_inv = gf2_inverse(&h_parity)
            .expect("H_parity is singular — cannot encode");

        LdpcEncoder {
            k,
            n: code.n,
            h_info,
            h_parity_inv,
        }
    }

    /// Encode info_bits (length K) -> codeword (length N).
    fn encode(&self, info_bits: &[u8]) -> Vec<u8> {
        let m = self.n - self.k;

        // s = H_info @ info_bits mod 2
        let mut s = vec![0u8; m];
        for i in 0..m {
            let mut acc = 0u32;
            for j in 0..self.k {
                acc += (self.h_info[i][j] & info_bits[j]) as u32;
            }
            s[i] = (acc % 2) as u8;
        }

        // parity = H_parity_inv @ s mod 2
        let mut parity = vec![0u8; m];
        for i in 0..m {
            let mut acc = 0u32;
            for j in 0..m {
                acc += (self.h_parity_inv[i][j] & s[j]) as u32;
            }
            parity[i] = (acc % 2) as u8;
        }

        // codeword = [info_bits | parity]
        let mut cw = Vec::with_capacity(self.n);
        cw.extend_from_slice(info_bits);
        cw.extend_from_slice(&parity);
        cw
    }
}

// ---------------------------------------------------------------------------
// OFDM sweep
// ---------------------------------------------------------------------------

/// Smart SNR start: skip very low SNRs where BER is guaranteed to be ~0.5
fn smart_snr_start(modulation: &str) -> f64 {
    match modulation {
        "QPSK" => -5.0,
        "16QAM" => 0.0,
        "64QAM" => 5.0,
        "256QAM" => 10.0,
        _ => -5.0,
    }
}

/// Build SNR range: coarse steps at low SNR, fine near waterfall.
fn build_snr_range(snr_min: f64, snr_max: f64) -> Vec<f64> {
    let mut snr_range = Vec::new();
    // -40 to -5: 2 dB steps
    let mut s = snr_min;
    while s < -5.0 && s < snr_max {
        snr_range.push(s);
        s += 2.0;
    }
    // -5 to snr_max: 1 dB steps
    s = if snr_min > -5.0 { snr_min } else { -5.0 };
    while s <= snr_max {
        snr_range.push(s);
        s += 1.0;
    }
    snr_range.sort_by(|a, b| a.partial_cmp(b).unwrap());
    snr_range.dedup();
    snr_range
}

fn run_ofdm_sweep(args: &Args) {
    let tv_dir = find_test_vectors_dir();
    let bm_path = format!("{}/base_matrix.json", tv_dir);
    let code = LdpcCode::from_json(&bm_path);
    let graph = code.build_tanner_graph();

    println!("OFDM Sweep: Code N={}, K={}, M={}, Z={}", code.n, code.k, code.m, code.z);

    // Pre-compute encoder
    println!("Pre-computing GF(2) encoder...");
    let encoder = LdpcEncoder::new(&code);
    println!("  Encoder ready.");

    let ofdm_params = OfdmParams::default_params();

    // Parse modulation/channel/estimator filters
    let modulations: Vec<String> = match &args.modulation {
        Some(m) => m.split(',').map(|s| s.trim().to_string()).collect(),
        None => vec!["QPSK".into(), "16QAM".into(), "64QAM".into()],
    };
    let channels: Vec<String> = match &args.channel {
        Some(c) => c.split(',').map(|s| s.trim().to_string()).collect(),
        None => vec!["flat".into(), "two_tap".into(), "tu6".into()],
    };
    let estimators: Vec<String> = match &args.estimator {
        Some(e) => e.split(',').map(|s| s.trim().to_string()).collect(),
        None => vec!["LS".into()],
    };

    let snr_range = build_snr_range(args.snr_min, args.snr_max);
    let n_seeds = 3u64;
    let seeds: Vec<u64> = (42..42 + n_seeds).collect();

    let mut results: HashMap<String, Vec<serde_json::Value>> = HashMap::new();

    // Try to load existing results for incremental saving
    if Path::new(&args.output).exists() {
        if let Ok(data) = fs::read_to_string(&args.output) {
            if let Ok(existing) = serde_json::from_str::<HashMap<String, Vec<serde_json::Value>>>(&data) {
                results = existing;
                println!("  Loaded {} existing curves from {}", results.len(), args.output);
            }
        }
    }

    let n_data_per_ofdm = ofdm_params.num_data;

    for modulation in &modulations {
        let constellation = get_constellation(modulation);

        for channel_name in &channels {
            for est_name in &estimators {
                let key = format!("{}_{}_{}", modulation, channel_name, est_name);

                // Skip if already computed
                if results.contains_key(&key) {
                    println!("\n=== {} === (already computed, skipping)", key);
                    continue;
                }

                println!("\n=== {} ===", key);
                let sweep_start = Instant::now();

                let smart_start = smart_snr_start(modulation);
                let mut curve: Vec<serde_json::Value> = Vec::new();
                let mut consecutive_zero = 0usize;

                for &snr_db in &snr_range {
                    // Early termination: 5 consecutive zero-BER points
                    if consecutive_zero >= 5 {
                        println!("  (early termination after 5 consecutive zero-BER points)");
                        break;
                    }

                    // For SNRs well below the useful range, output noise floor
                    if snr_db < smart_start - 10.0 {
                        let point = serde_json::json!({
                            "snr_db": snr_db,
                            "ber_coded": 0.5,
                            "ber_uncoded": 0.5,
                            "avg_iter": 50.0,
                            "fer": 1.0,
                        });
                        curve.push(point);
                        consecutive_zero = 0;
                        println!("  SNR={:>6.1} dB | SKIP | BER=5.0000e-01 | uncoded=5.0000e-01 | iter=50.0",
                                 snr_db);
                        continue;
                    }

                    let mut ber_sum = 0.0f64;
                    let mut ber_unc_sum = 0.0f64;
                    let mut iter_sum = 0usize;
                    let mut conv_count = 0usize;

                    for &seed in &seeds {
                        let mut rng = StdRng::seed_from_u64(seed);

                        // Random info bits
                        let info_bits: Vec<u8> = (0..code.k).map(|_| rng.gen_range(0..2)).collect();

                        // LDPC encode
                        let coded_bits = encoder.encode(&info_bits);

                        // QAM map
                        let qam_symbols = qam_map(&coded_bits, &constellation);

                        // OFDM modulate
                        let tx_signal = ofdm_modulate(&qam_symbols, &ofdm_params);

                        // Channel: multipath + AWGN
                        let ch_model = get_channel_model(channel_name);
                        let ch_taps = make_channel_taps(&ch_model, &mut rng);
                        let rx_after_mp = apply_multipath(&tx_signal, &ch_taps);
                        let rx_signal = apply_awgn(&rx_after_mp, snr_db, &mut rng);

                        // Compute noise variance for estimator/equalizer
                        let sig_power: f64 = tx_signal.iter()
                            .map(|(r, i)| r * r + i * i)
                            .sum::<f64>() / tx_signal.len() as f64;
                        let snr_linear = 10.0_f64.powf(snr_db / 10.0);
                        let noise_var = if snr_linear > 0.0 { sig_power / snr_linear } else { 1e-10 };

                        // Number of OFDM symbols needed
                        let n_qam = qam_symbols.len();
                        let n_ofdm = (n_qam + n_data_per_ofdm - 1) / n_data_per_ofdm;

                        // OFDM demodulate
                        let (_raw, eq_symbols, _h_est, eff_noise) = ofdm_demodulate(
                            &rx_signal, &ofdm_params, n_ofdm,
                            est_name, "ZF", noise_var,
                        );

                        // Soft demap -> LLR
                        let eq_trimmed = if eq_symbols.len() > n_qam {
                            &eq_symbols[..n_qam]
                        } else {
                            &eq_symbols
                        };
                        let demapping_noise = if eff_noise.is_empty() {
                            noise_var
                        } else {
                            eff_noise.iter().sum::<f64>() / eff_noise.len() as f64
                        };
                        let soft_llr_f64 = qam_demap_soft(eq_trimmed, demapping_noise, &constellation);

                        // Trim/pad LLR to code length, convert to f32
                        let n_coded = code.n;
                        let mut llr_f32 = vec![0.0f32; n_coded];
                        for i in 0..n_coded.min(soft_llr_f64.len()) {
                            llr_f32[i] = soft_llr_f64[i] as f32;
                        }

                        // LDPC decode
                        let mut decoder = MinSumDecoder::new(&code, graph.clone(), 0.75, 50);
                        let result = decoder.decode(&llr_f32);

                        // Compute BER
                        // Uncoded: hard decision on LLR
                        let ber_uncoded: f64 = llr_f32.iter().take(code.k)
                            .zip(info_bits.iter())
                            .filter(|(&llr, &ib)| {
                                let hard = if llr < 0.0 { 1u8 } else { 0u8 };
                                hard != ib
                            })
                            .count() as f64 / code.k as f64;

                        // Coded: post-LDPC
                        let ber_coded: f64 = result.decoded_bits.iter().take(code.k)
                            .zip(info_bits.iter())
                            .filter(|(a, b)| a != b)
                            .count() as f64 / code.k as f64;

                        ber_sum += ber_coded;
                        ber_unc_sum += ber_uncoded;
                        iter_sum += result.iterations;
                        if result.converged {
                            conv_count += 1;
                        }
                    }

                    let avg_ber = ber_sum / n_seeds as f64;
                    let avg_ber_unc = ber_unc_sum / n_seeds as f64;
                    let avg_iter = iter_sum as f64 / n_seeds as f64;
                    let fer = 1.0 - conv_count as f64 / n_seeds as f64;

                    if avg_ber == 0.0 {
                        consecutive_zero += 1;
                    } else {
                        consecutive_zero = 0;
                    }

                    let status = if conv_count == n_seeds as usize {
                        "CONV"
                    } else if conv_count > 0 {
                        "PART"
                    } else {
                        "FAIL"
                    };
                    println!(
                        "  SNR={:>6.1} dB | {} | BER={:.4e} | uncoded={:.4e} | iter={:.1}",
                        snr_db, status, avg_ber, avg_ber_unc, avg_iter
                    );

                    let point = serde_json::json!({
                        "snr_db": snr_db,
                        "ber_coded": avg_ber,
                        "ber_uncoded": avg_ber_unc,
                        "avg_iter": avg_iter,
                        "fer": fer,
                    });
                    curve.push(point);
                }

                let elapsed = sweep_start.elapsed();
                println!("  [{} done in {:.1}s, {} points]", key, elapsed.as_secs_f64(), curve.len());

                results.insert(key, curve);

                // Incremental save after each combo
                let json_out = serde_json::to_string_pretty(&results).unwrap();
                fs::write(&args.output, &json_out).unwrap();
                println!("  [saved {} curves to {}]", results.len(), args.output);
            }
        }
    }

    println!("\n=== OFDM sweep complete: {} curves saved to {} ===", results.len(), args.output);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

fn main() {
    let args = Args::parse();

    if args.ofdm_sweep {
        run_ofdm_sweep(&args);
        return;
    }

    // Default behavior: test vector validation + BPSK sweep
    let tv_dir = match &args.test_vectors {
        Some(p) => p.clone(),
        None => find_test_vectors_dir(),
    };
    println!("Test vectors directory: {}", tv_dir);

    // Load code
    let bm_path = format!("{}/base_matrix.json", tv_dir);
    let code = LdpcCode::from_json(&bm_path);
    let graph = code.build_tanner_graph();
    println!(
        "Code: N={}, K={}, M={}, Z={}, edges={}",
        code.n, code.k, code.m, code.z, graph.num_edges
    );

    let mut decoder = MinSumDecoder::new(&code, graph, 0.75, 50);

    // ===== Test Vector Validation =====
    println!("\n===== Test Vector Validation =====");
    let labels = ["noiseless", "clean", "waterfall", "high_noise"];
    let mut all_pass = true;

    for label in &labels {
        let llr_path = format!("{}/llr_snr_{}_f32.bin", tv_dir, label);
        let dec_path = format!("{}/decoded_snr_{}.bin", tv_dir, label);
        let iter_path = format!("{}/num_iters_snr_{}.txt", tv_dir, label);

        let llr = load_f32_bin(&llr_path);
        let expected_bits = load_decoded_bin(&dec_path);
        let expected_iters = load_num_iters(&iter_path);

        let start = Instant::now();
        let result = decoder.decode(&llr);
        let elapsed = start.elapsed();

        let bits_match = result.decoded_bits == expected_bits;
        let iters_match = result.iterations == expected_iters;

        let status = if bits_match && iters_match {
            "PASS"
        } else {
            all_pass = false;
            "FAIL"
        };

        let bit_errors: usize = result
            .decoded_bits
            .iter()
            .zip(expected_bits.iter())
            .filter(|(a, b)| a != b)
            .count();

        println!(
            "  {} | SNR={:<12} | converged={:<5} | iters={:>2}/{:>2} | bit_errs={:>3} | {:.2?}",
            status,
            label,
            result.converged,
            result.iterations,
            expected_iters,
            bit_errors,
            elapsed,
        );
    }

    if all_pass {
        println!("All test vectors PASSED (bit-exact match with Python).");
    } else {
        println!("WARNING: Some test vectors FAILED.");
    }

    // ===== BER Sweep =====
    if !args.ber_sweep && !args.ofdm_sweep {
        // Default: run BPSK sweep
        println!("\n===== BER Sweep (all-zero codeword, BPSK+AWGN) =====");
        println!("snr_db,ber,fer,avg_iter");

        let snr_points: Vec<f32> =
            vec![-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0];
        let num_frames = 100;
        let code_rate = code.k as f32 / code.n as f32;
        let codeword = all_zero_codeword(code.n);

        // Need a new decoder since the graph was moved
        let graph2 = code.build_tanner_graph();
        let mut decoder2 = MinSumDecoder::new(&code, graph2, 0.75, 50);

        for &snr_db in &snr_points {
            let sigma2 = compute_sigma2(code_rate, snr_db);
            let sigma = sigma2.sqrt();

            let mut total_bit_errors: usize = 0;
            let mut total_frame_errors: usize = 0;
            let mut total_iters: usize = 0;

            let mut rng = StdRng::seed_from_u64(42);
            let normal = Normal::new(0.0f32, sigma).unwrap();

            for _frame in 0..num_frames {
                // BPSK modulate
                let bpsk = bpsk_modulate(&codeword);

                // Add AWGN noise
                let received: Vec<f32> = bpsk
                    .iter()
                    .map(|&s| s + normal.sample(&mut rng))
                    .collect();

                // Compute LLR
                let llr = compute_llr(&received, sigma2);

                // Decode
                let result = decoder2.decode(&llr);

                // Count errors in info bits only (matching Python convention)
                let bit_errors: usize = result
                    .decoded_bits
                    .iter()
                    .take(code.k)
                    .zip(codeword.iter().take(code.k))
                    .filter(|(a, b)| a != b)
                    .count();

                total_bit_errors += bit_errors;
                if bit_errors > 0 {
                    total_frame_errors += 1;
                }
                total_iters += result.iterations;
            }

            let ber = total_bit_errors as f64 / (num_frames as f64 * code.k as f64);
            let fer = total_frame_errors as f64 / num_frames as f64;
            let avg_iter = total_iters as f64 / num_frames as f64;

            println!("{:.1},{:.6e},{:.4},{:.2}", snr_db, ber, fer, avg_iter);
        }
    }
}

//! LDPC decoder CLI — test vector validation and BER sweep tool.
//!
//! Usage:
//!   ldpc-cli [--test-vectors <path>] [--ber-sweep]
//!
//! Default: validates decoded bits against Python test vectors, then runs BER sweep.

use ldpc_core::code::LdpcCode;
use ldpc_core::decoder::{load_decoded_bin, load_f32_bin, load_num_iters, MinSumDecoder};

use rand::rngs::StdRng;
use rand::SeedableRng;
use rand_distr::{Distribution, Normal};

use std::path::Path;
use std::time::Instant;

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

fn main() {
    let tv_dir = find_test_vectors_dir();
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
    println!("\n===== BER Sweep (all-zero codeword, BPSK+AWGN) =====");
    println!("snr_db,ber,fer,avg_iter");

    let snr_points: Vec<f32> = vec![-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0];
    let num_frames = 100;
    let code_rate = code.k as f32 / code.n as f32;
    let codeword = all_zero_codeword(code.n);

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
            let result = decoder.decode(&llr);

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

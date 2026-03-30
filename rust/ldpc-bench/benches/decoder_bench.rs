//! Criterion benchmarks for LDPC decoder throughput.

use criterion::{criterion_group, criterion_main, Criterion};
use ldpc_core::code::LdpcCode;
use ldpc_core::decoder::{load_f32_bin, MinSumDecoder};
use std::path::Path;

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
    panic!("Could not find test_vectors directory.");
}

fn bench_single_frame_decode(c: &mut Criterion) {
    let tv_dir = find_test_vectors_dir();
    let bm_path = format!("{}/base_matrix.json", tv_dir);
    let code = LdpcCode::from_json(&bm_path);
    let graph = code.build_tanner_graph();

    // Use the "clean" SNR point (2.0 dB) — fast convergence
    let llr_path = format!("{}/llr_snr_clean_f32.bin", tv_dir);
    let llr = load_f32_bin(&llr_path);

    let mut decoder = MinSumDecoder::new(&code, graph, 0.75, 50);

    c.bench_function("decode_clean_2dB", |b| {
        b.iter(|| {
            let result = decoder.decode(&llr);
            criterion::black_box(&result);
        })
    });

    // Also benchmark high-noise case (max iterations)
    let llr_noisy_path = format!("{}/llr_snr_high_noise_f32.bin", tv_dir);
    let llr_noisy = load_f32_bin(&llr_noisy_path);

    c.bench_function("decode_high_noise_m2dB", |b| {
        b.iter(|| {
            let result = decoder.decode(&llr_noisy);
            criterion::black_box(&result);
        })
    });
}

criterion_group!(benches, bench_single_frame_decode);
criterion_main!(benches);

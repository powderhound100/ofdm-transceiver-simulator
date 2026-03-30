# External References and Validation Sources

Known open-source projects we can leverage or validate against. No open-source
ATSC 3.0 LDPC decoder (software or RTL) exists — this project would be the first.

## Priority 1: gr-atsc3 (ATSC 3.0 Base Matrices)

- **Repo:** https://github.com/drmpeg/gr-atsc3
- **Author:** Ron Economos (drmpeg), well-known GNU Radio contributor
- **License:** GPL-3.0
- **Verified against:** Official ATSC 3.0 V&V test suite
- **What it has:**
  - Complete A/322 LDPC parity accumulator tables for all 24 codes (12 rates × 2 frame lengths)
  - Located in `lib/ldpc_bb_impl.cc` (lines 251–1713) as `const uint16_t` arrays
  - Parameters (kbch, nbch, q, m1, m2, code type) in `lib/params.cc`
  - V&V test flowgraphs in `examples/`

### ATSC 3.0 LDPC Code Types

| Type | Rates | Structure | Encoding |
|------|-------|-----------|----------|
| **Type B (IRA)** | 6/15, 8/15–13/15 | Single accumulator, parameter q | Simple: XOR info bits per LUT row, then accumulate p[j] ^= p[j-1] |
| **Type A (MET)** | 2/15–5/15, 7/15 | Dual accumulator, parameters q1, q2, m1, m2 | Two-phase: first m1 parity bits with q1, then m2 parity bits with q2 |

### Normal Frame Parameters (N=64800)

| Rate | kbch | nbch | Type | q/q1 | q2 | m1 | m2 |
|------|------|------|------|------|----|----|----|
| 2/15 | 8448 | 8640 | A | q1=5 | 151 | 1800 | 54360 |
| 3/15 | 12768 | 12960 | A | q1=5 | 139 | 1800 | 50040 |
| 4/15 | 17088 | 17280 | A | q1=5 | 127 | 1800 | 45720 |
| 5/15 | 21408 | 21600 | A | q1=4 | 116 | 1440 | 41760 |
| 6/15 | 25728 | 25920 | B | q=108 | - | - | - |
| 7/15 | 30048 | 30240 | A | q1=3 | 93 | 1080 | 33480 |
| 8/15 | 34368 | 34560 | B | q=84 | - | - | - |
| 9/15 | 38688 | 38880 | B | q=72 | - | - | - |
| 10/15 | 43008 | 43200 | B | q=60 | - | - | - |
| 11/15 | 47328 | 47520 | B | q=48 | - | - | - |
| 12/15 | 51648 | 51840 | B | q=36 | - | - | - |
| 13/15 | 55968 | 56160 | B | q=24 | - | - | - |

### How We Use It

1. **Extract tables** from `ldpc_bb_impl.cc` into our Python `ldpc_code.py` format
2. **Validate our encoder** against gr-atsc3's encoder (same inputs → same codewords)
3. **Use V&V test cases** as additional verification beyond our BER tests
4. **Note:** The tables are from the public A/322 standard; gr-atsc3 is just the most convenient source

---

## Priority 2: AFF3CT (Algorithm Validation + BER Reference)

- **Repo:** https://github.com/aff3ct/aff3ct
- **License:** MIT
- **What it has:**
  - High-performance C++ LDPC encoder/decoder with SIMD (SSE/AVX/NEON)
  - Min-Sum variants: MIN, MINL, MINS/min-star, plus Belief Propagation
  - DVB-S2 codes built-in; custom codes via AList/QC format (`--dec-h-path`)
  - BER/FER reference curves in `error_rate_references` repo
  - Configuration files: https://github.com/aff3ct/configuration_files
- **Related:** https://github.com/daniestevez/aff3ct-ldpc-decoder (CLI wrapper)

### How We Use It

1. **Convert** our ATSC 3.0 H matrices to AList format
2. **Run AFF3CT** with same SNR points → get independent BER curves
3. **Cross-validate** our Python/Rust decoder BER against AFF3CT's output
4. **Compare** min-sum normalization performance (our α=0.75 vs AFF3CT's variants)

---

## Priority 3: FEC-Archive-Verilog (FPGA RTL Architecture Reference)

- **Repo:** https://github.com/Lcrypto/FEC-Archive-Verilog
- **License:** (check repo)
- **What it has:**
  - WiMAX (802.16e) QC-LDPC **Normalized Min-Sum decoder** in Verilog
  - Rates 1/2, 2/3B, 3/4A, 5/6 at length 2304
  - Synthesized on Cyclone IV: 210 MHz, 11872 LCs, 37 M9K BRAMs
  - CNU, VNU, barrel shifter RTL modules

### How We Use It

1. **Study RTL patterns** for CNU/VNU pipeline, barrel shifter, BRAM partitioning
2. **Compare** our resource estimates against their synthesis results
3. **Adapt** their QC-LDPC routing structure for Z=360 (they use Z=96)
4. **Not directly reusable** — different code parameters, but same decoder algorithm

---

## Priority 4: dvb_fpga (LDPC Encoder RTL + Test Infrastructure)

- **Repo:** https://github.com/OpenResearchInstitute/dvb_fpga
- **License:** CERN-OHL-W v2
- **What it has:**
  - DVB-S2 LDPC **encoder** in VHDL with AXI-Stream interfaces
  - Table ROM organization (`ldpc_tables_pkg.vhd`) — same format as A/322
  - VUnit test framework integration
  - Resource: ~1017 LUTs + 558 FFs for encoder

### How We Use It

1. **Adapt** table ROM organization for ATSC 3.0 parameters
2. **Follow** their AXI-Stream interface patterns for our FPGA I/O
3. **Their decoder is missing** — they want exactly what we're building
4. The DVB-S2 Type B (IRA) encoding is identical to ATSC 3.0 Type B

---

## Priority 5: Other References

| Project | What | Relevance |
|---------|------|-----------|
| https://github.com/adimitris/verilog-LDPC-decoder | Tiny SystemVerilog min-sum decoder (length-10) | Educational only |
| http://www.spiral.net/hardware/ldpc.html | LDPC decoder RTL generator (any QC code) | Non-commercial license; validation reference |
| https://github.com/biren15/Design-and-Verification-of-LDPC-Decoder | Verilog min-sum + MATLAB co-design | Quantization strategy reference |
| https://github.com/cea-wind/hls_ldpc_dec | HLS-based WiMAX LDPC decoder | Alternative design methodology |
| https://github.com/DavidToddMiller/gr-aff3ct_codes | GNU Radio + AFF3CT integration | Potential GNU Radio integration path |

---

## Validation Strategy Using References

```
Our Python decoder ──────── compare BER ────── AFF3CT (with our H matrices)
        │
        ├── compare encoder output ──────────── gr-atsc3 encoder
        │
        └── generate test vectors ──┬──────── Our Rust decoder (bit-exact)
                                    │
                                    └──────── Our FPGA sim (bit-exact 6-bit)

Our FPGA RTL architecture ── informed by ──── FEC-Archive-Verilog (CNU/VNU patterns)
                          └── informed by ──── dvb_fpga (AXI-Stream, table ROM)
```

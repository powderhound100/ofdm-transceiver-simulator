# Hardware Planning — From Simulation to Real RF

## ATSC 3.0 RF Specifications

| Parameter | Value |
|-----------|-------|
| Frequency band | UHF 470-698 MHz (US channels 14-51) |
| Channel bandwidth | 6 MHz (North America) |
| FFT sizes | 8K, 16K, 32K |
| Modulation | QPSK, 16QAM, 64QAM, 256QAM, 1024QAM, 4096QAM |
| LDPC code lengths | 16,200 (short) and 64,800 (normal) |
| LDPC code rates | 2/15 to 13/15 (12 rates) |
| Peak-to-Average Power Ratio | ~10-12 dB (typical for OFDM) |

## SDR Hardware Comparison

| SDR | Freq Range | Max BW | ADC Bits | Price | Verdict |
|-----|-----------|--------|----------|-------|---------|
| **RTL-SDR v4** | 24-1766 MHz | 2.4 MHz | 8 | ~$30 | Too narrow (need 6 MHz). Good for FM/ADS-B but not ATSC 3.0 |
| **SDRplay RSP1B** | 1 kHz-2 GHz | 10 MHz | 14 | ~$120 | **Recommended.** Covers full 6 MHz with margin. 14-bit gives the dynamic range OFDM needs (high PAPR). SoapySDR + GNU Radio compatible |
| **HackRF One** | 1-6000 MHz | 20 MHz | 8 | ~$350 | Sufficient BW but 8-bit ADC limits SNR to ~48 dB. Usable but not ideal for high-order QAM |
| **Adalm-Pluto** | 325-3800 MHz | 20 MHz | 12 | ~$200 | Good all-around but 325 MHz low cutoff is marginal for low UHF channels. Fine for channels above ~20 |
| **Ettus USRP B200** | 70-6000 MHz | 56 MHz | 12 | ~$1500 | Overkill for single-channel work. Justified if doing multi-channel or wideband capture |

### Recommendation: SDRplay RSP1B

Best price-to-performance for ATSC 3.0 reception:
- 14-bit ADC handles OFDM's 10-12 dB PAPR without clipping
- 10 MHz bandwidth captures the full 6 MHz channel + guard bands
- Covers entire UHF TV band with margin
- Well-supported: SoapySDR driver, GNU Radio source block, Python bindings
- ~$120 is a reasonable entry point

## Antenna Requirements

| Tier | Antenna | Gain | Notes |
|------|---------|------|-------|
| Basic | Telescoping whip / rabbit ears | ~0 dBi | Works within 10-20 miles of transmitter |
| Better | UHF loop or bowtie (e.g., ClearStream 1MAX) | ~4-6 dBi | Good for indoor/attic use, 20-40 miles |
| Best | Log-periodic or Yagi (e.g., Antennas Direct 91XG) | ~10-15 dBi | Outdoor, pointed at transmitter, 40-60+ miles |

**Connection:** Most SDRs use SMA connectors. TV antennas use 75-ohm F connectors. You'll need an **F-to-SMA adapter** (~$5). The impedance mismatch (75 vs 50 ohm) causes ~0.2 dB loss — negligible for our purposes.

## Signal Levels

Typical received signal strength at antenna:
- Strong local (< 10 miles): -30 to -40 dBm
- Medium (10-30 miles): -40 to -60 dBm
- Weak (30-60 miles): -60 to -80 dBm
- ATSC 3.0 minimum for reliable decode: approximately -85 dBm (depends on code rate)

The SDRplay RSP1B's sensitivity is about -110 dBm at 500 MHz, giving plenty of margin.

## Software Stack

| Layer | Tool | Purpose |
|-------|------|---------|
| Capture | SoapySDR + `pyrtlsdr` or `SoapySDR` Python bindings | Raw IQ sample capture |
| Signal processing | NumPy + SciPy | FFT, filtering, channel estimation |
| OFDM demod | `python/ofdm/` (this project) | CP removal, FFT, equalization |
| LDPC decode | `python/decoder.py` (this project) | Soft-decision decoding |
| Visualization | Plotly Dash dashboard | Real-time IQ/spectrum/constellation plots |
| Integration | GNU Radio + gr-atsc3 | Full protocol stack (future) |

## Roadmap: Simulation to Real RF

### Stage 0: Baseband BPSK + AWGN (DONE)
- **Input:** Synthetic bits
- **Channel:** Flat AWGN via `channel.py`
- **Output:** LDPC decoded bits
- **Status:** Complete. BER waterfall verified. Python + Rust + FPGA RTL.

### Stage 1: OFDM + Flat AWGN (THIS PHASE)
- **Input:** Synthetic bits
- **Processing:** QAM mapping, OFDM IFFT+CP, flat AWGN, FFT, equalization, LLR
- **Output:** LDPC decoded bits through OFDM chain
- **Validates:** OFDM modulator/demodulator, QAM soft demapping, pilot-based channel estimation on flat channel

### Stage 2: OFDM + Multipath Fading
- **Input:** Synthetic bits
- **Channel:** TDL multipath models (TU-6, frequency-selective fading)
- **Output:** LDPC decoded bits, channel estimation accuracy
- **Validates:** Equalization under frequency-selective channels, pilot interpolation quality

### Stage 3: Recorded IQ File Playback
- **Input:** Pre-recorded `.raw` or `.cf32` IQ files from real ATSC 3.0 broadcasts
- **Processing:** File load, OFDM demod, LDPC decode
- **Validates:** Real-world signal handling, timing sync, frequency offset estimation
- **How to get files:** Use `rtl_sdr` or `SoapySDRUtil` to capture, or download samples from online SDR archives

### Stage 4: Live SDR Capture
- **Input:** Real-time IQ from SDRplay RSP1B
- **Processing:** Streaming OFDM demod + LDPC decode
- **Validates:** End-to-end real-time receive pipeline
- **Requirements:** SDR hardware + antenna + local ATSC 3.0 broadcast

### Stage 5: GNU Radio Integration (Future)
- **Input:** GNU Radio flowgraph with `gr-atsc3` blocks
- **Processing:** Full ATSC 3.0 protocol stack (bootstrap, preamble, L1 signaling, payload)
- **Output:** Decoded transport stream
- **Our contribution:** LDPC decoder as a GNU Radio out-of-tree (OOT) module, callable from `gr-atsc3` flowgraph

## Finding Local ATSC 3.0 Broadcasts

ATSC 3.0 deployment is ongoing in the US. To find active stations near you:

1. Visit [rabbitears.info](https://www.rabbitears.info/market.php) and search your market
2. Look for stations marked "ATSC 3.0" or "NEXTGEN TV"
3. Note the RF channel number — this gives you the center frequency
4. RF channel to frequency: `center_freq = 473 + 6 * (channel - 14)` MHz (for UHF channels 14-51)

**Example:** RF channel 24 = 473 + 6*(24-14) = 533 MHz center frequency.

## Cost Summary

| Item | Price |
|------|-------|
| SDRplay RSP1B | ~$120 |
| F-to-SMA adapter | ~$5 |
| Basic UHF antenna | ~$20-40 |
| **Total minimum** | **~$145-165** |

Optional: outdoor antenna with mount ($50-100), coax cable run ($20-40), LNA/preamp for weak signals ($30-50).

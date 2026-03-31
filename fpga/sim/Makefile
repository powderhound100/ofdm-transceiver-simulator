# =============================================================================
# Makefile — OFDM Transceiver FPGA Simulation
# =============================================================================
# Supports Icarus Verilog (iverilog) and Verilator
#
# Targets:
#   Existing LDPC:
#     make tb_barrel_shifter  — Run barrel shifter testbench
#     make tb_min2            — Run min2 finder testbench
#     make tb_cnu             — Run check node unit testbench
#     make tb_vnu             — Run variable node unit testbench
#     make tb_top             — Run top-level LDPC integration testbench
#
#   Channel Model (Phase A):
#     make tb_fir_sparse      — Sparse FIR filter testbench
#     make tb_fir_dense32     — Dense 32-tap FIR testbench
#     make tb_fir_dense64     — Dense 64-tap FIR testbench
#     make tb_fir_dense128    — Dense 128-tap FIR testbench
#     make tb_fir_dense256    — Dense 256-tap FIR testbench
#     make tb_awgn            — AWGN noise generator testbench
#     make tb_channel_model   — Channel model integration testbench
#
#   OFDM Receiver (Phase B):
#     make tb_cp_removal      — CP removal testbench
#     make tb_fft             — 64-point FFT testbench
#     make tb_demux           — Subcarrier demux testbench
#     make tb_ch_est          — Channel estimator testbench
#     make tb_eq              — Equalizer testbench
#     make tb_demap           — Soft demapper testbench
#     make tb_frame           — Frame controller testbench
#
#   OFDM Transmitter (Phase F):
#     make tb_encoder         — LDPC encoder testbench
#     make tb_mapper          — QAM mapper testbench
#     make tb_cp_insert       — CP insertion testbench
#     make tb_ifft            — 64-point IFFT testbench
#     make tb_mux             — Subcarrier mux testbench
#
#   Sync / Estimation (Phase G):
#     make tb_noise_est       — Noise estimator testbench
#     make tb_sym_sync        — Symbol sync testbench
#     make tb_cfo_corr        — CFO corrector testbench
#
#   FIR Comparison:
#     make tb_fir_compare     — FIR variant comparison testbench
#
#   Integration:
#     make tb_ofdm_tx         — OFDM TX integration testbench
#     make tb_ofdm_rx         — OFDM RX integration testbench
#     make tb_loopback        — Full loopback (TX->CH->RX->LDPC) testbench
#
#   Aggregate:
#     make all_ldpc           — All LDPC testbenches
#     make all_channel        — All channel model testbenches (incl. dense FIR + compare)
#     make all_ofdm_rx        — All OFDM RX testbenches (incl. RX integration)
#     make all_ofdm_tx        — All OFDM TX testbenches (incl. TX integration)
#     make all_sync           — All sync/estimation testbenches
#     make all_integration    — All integration testbenches (TX, RX, loopback)
#     make all                — Run ALL testbenches
#     make clean              — Remove generated files
# =============================================================================

# Tool selection
IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator

# Directories
RTL_DIR  := ../rtl
TB_DIR   := ../tb
TV_DIR   := ../../test_vectors

# Common iverilog flags
IVFLAGS  := -g2012 -Wall -I$(RTL_DIR)

# =============================================================================
# RTL Source File Groups
# =============================================================================

# --- Existing LDPC ---
RTL_BARREL   := $(RTL_DIR)/barrel_shifter.sv
RTL_SIGN_XOR := $(RTL_DIR)/sign_xor_tree.sv
RTL_MIN2     := $(RTL_DIR)/min2_finder.sv
RTL_CNU      := $(RTL_DIR)/check_node_unit.sv $(RTL_BARREL) $(RTL_SIGN_XOR) $(RTL_MIN2)
RTL_VNU      := $(RTL_DIR)/variable_node_unit.sv
RTL_MSG_RAM  := $(RTL_DIR)/message_ram.sv
RTL_BM_ROM   := $(RTL_DIR)/base_matrix_rom.sv
RTL_ITER     := $(RTL_DIR)/iteration_ctrl.sv
RTL_SYNDROME := $(RTL_DIR)/syndrome_checker.sv
RTL_LLR_BUF  := $(RTL_DIR)/llr_input_buffer.sv
RTL_OUT_BUF  := $(RTL_DIR)/output_buffer.sv
RTL_LDPC_TOP := $(RTL_DIR)/ldpc_top.sv

RTL_LDPC_ALL := $(RTL_DIR)/barrel_shifter.sv \
               $(RTL_DIR)/sign_xor_tree.sv \
               $(RTL_DIR)/min2_finder.sv \
               $(RTL_DIR)/check_node_unit.sv \
               $(RTL_VNU) $(RTL_MSG_RAM) $(RTL_BM_ROM) $(RTL_ITER) $(RTL_SYNDROME) \
               $(RTL_LLR_BUF) $(RTL_OUT_BUF) $(RTL_LDPC_TOP)

# --- Channel Model (Phase A) ---
RTL_LFSR     := $(RTL_DIR)/lfsr64.sv
RTL_FIR_SP   := $(RTL_DIR)/channel_fir_sparse.sv
RTL_FIR_D32  := $(RTL_DIR)/channel_fir_dense32.sv
RTL_FIR_D64  := $(RTL_DIR)/channel_fir_dense64.sv
RTL_FIR_D128 := $(RTL_DIR)/channel_fir_dense128.sv
RTL_FIR_D256 := $(RTL_DIR)/channel_fir_dense256.sv
RTL_AWGN     := $(RTL_LFSR) $(RTL_DIR)/awgn_generator.sv
RTL_PROF_ROM := $(RTL_DIR)/channel_profile_rom.sv
RTL_CH_TOP   := $(RTL_DIR)/channel_model_top.sv $(RTL_FIR_SP) $(RTL_AWGN) $(RTL_PROF_ROM)

# --- Sync / Estimation (Phase G) ---
RTL_NOISE_EST := $(RTL_DIR)/noise_estimator.sv
RTL_SYM_SYNC  := $(RTL_DIR)/symbol_sync.sv
RTL_CFO_CORR  := $(RTL_DIR)/cfo_corrector.sv

# --- OFDM Receiver (Phase B) ---
RTL_CP_REM   := $(RTL_DIR)/cp_removal.sv
RTL_FFT_BF   := $(RTL_DIR)/fft_butterfly.sv
RTL_TW_ROM   := $(RTL_DIR)/twiddle_rom.sv
RTL_FFT      := $(RTL_FFT_BF) $(RTL_TW_ROM) $(RTL_DIR)/fft_64pt.sv
RTL_DEMUX    := $(RTL_DIR)/subcarrier_demux.sv
RTL_CH_EST   := $(RTL_DIR)/channel_estimator.sv
RTL_ALIGN    := $(RTL_DIR)/data_align_buffer.sv
RTL_RECIP    := $(RTL_DIR)/reciprocal_lut.sv
RTL_EQ       := $(RTL_DIR)/equalizer.sv $(RTL_RECIP)
RTL_DEMAP    := $(RTL_DIR)/soft_demapper.sv
RTL_FRAME    := $(RTL_DIR)/frame_controller.sv
RTL_RX_TOP   := $(RTL_DIR)/ofdm_rx_top.sv

RTL_OFDM_RX  := $(RTL_CP_REM) $(RTL_FFT) $(RTL_DEMUX) $(RTL_CH_EST) \
                $(RTL_ALIGN) $(RTL_EQ) $(RTL_DEMAP) $(RTL_FRAME) $(RTL_RX_TOP)

# --- OFDM Transmitter (Phase F) ---
RTL_ENCODER  := $(RTL_DIR)/ldpc_encoder.sv $(RTL_BM_ROM)
RTL_MAPPER   := $(RTL_DIR)/qam_mapper.sv
RTL_IFFT     := $(RTL_FFT) $(RTL_DIR)/ifft_64pt.sv
RTL_SUB_MUX  := $(RTL_DIR)/subcarrier_mux.sv
RTL_CP_INS   := $(RTL_DIR)/cp_insertion.sv
RTL_TX_TOP   := $(RTL_DIR)/ofdm_tx_top.sv

RTL_OFDM_TX  := $(RTL_ENCODER) $(RTL_MAPPER) $(RTL_IFFT) $(RTL_SUB_MUX) \
                $(RTL_CP_INS) $(RTL_TX_TOP)

# --- Loopback ---
RTL_LOOPBACK := $(RTL_DIR)/ofdm_loopback_top.sv

# =============================================================================
# Testbench Source Files
# =============================================================================
TB_BARREL     := $(TB_DIR)/tb_barrel_shifter.sv
TB_MIN2       := $(TB_DIR)/tb_min2_finder.sv
TB_CNU        := $(TB_DIR)/tb_check_node_unit.sv
TB_VNU        := $(TB_DIR)/tb_variable_node_unit.sv
TB_LDPC_TOP   := $(TB_DIR)/tb_ldpc_top.sv
TB_FIR_SP     := $(TB_DIR)/tb_channel_fir_sparse.sv
TB_FIR_D32    := $(TB_DIR)/tb_channel_fir_dense32.sv
TB_FIR_D64    := $(TB_DIR)/tb_channel_fir_dense64.sv
TB_FIR_D128   := $(TB_DIR)/tb_channel_fir_dense128.sv
TB_FIR_D256   := $(TB_DIR)/tb_channel_fir_dense256.sv
TB_AWGN       := $(TB_DIR)/tb_awgn_generator.sv
TB_CH_MODEL   := $(TB_DIR)/tb_channel_model_top.sv
TB_CP_REM     := $(TB_DIR)/tb_cp_removal.sv
TB_FFT        := $(TB_DIR)/tb_fft_64pt.sv
TB_DEMUX      := $(TB_DIR)/tb_subcarrier_demux.sv
TB_CH_EST     := $(TB_DIR)/tb_channel_estimator.sv
TB_EQ         := $(TB_DIR)/tb_equalizer.sv
TB_DEMAP      := $(TB_DIR)/tb_soft_demapper.sv
TB_FRAME      := $(TB_DIR)/tb_frame_controller.sv
TB_ENCODER    := $(TB_DIR)/tb_ldpc_encoder.sv
TB_MAPPER     := $(TB_DIR)/tb_qam_mapper.sv
TB_CP_INS     := $(TB_DIR)/tb_cp_insertion.sv
TB_IFFT       := $(TB_DIR)/tb_ifft_64pt.sv
TB_SUB_MUX    := $(TB_DIR)/tb_subcarrier_mux.sv
TB_NOISE_EST  := $(TB_DIR)/tb_noise_estimator.sv
TB_SYM_SYNC   := $(TB_DIR)/tb_symbol_sync.sv
TB_CFO_CORR   := $(TB_DIR)/tb_cfo_corrector.sv
TB_FIR_CMP    := $(TB_DIR)/tb_fir_compare.sv
TB_OFDM_TX    := $(TB_DIR)/tb_ofdm_tx_top.sv
TB_OFDM_RX    := $(TB_DIR)/tb_ofdm_rx_top.sv
TB_LOOPBACK   := $(TB_DIR)/tb_ofdm_loopback.sv

# =============================================================================
# Phony targets
# =============================================================================
.PHONY: all all_ldpc all_channel all_ofdm_rx all_ofdm_tx all_sync all_integration \
        clean lint \
        tb_barrel_shifter tb_min2 tb_cnu tb_vnu tb_top \
        tb_fir_sparse tb_fir_dense32 tb_fir_dense64 tb_fir_dense128 tb_fir_dense256 \
        tb_fir_compare tb_awgn tb_channel_model \
        tb_cp_removal tb_fft tb_demux tb_ch_est tb_eq tb_demap tb_frame \
        tb_encoder tb_mapper tb_cp_insert tb_ifft tb_mux \
        tb_noise_est tb_sym_sync tb_cfo_corr \
        tb_ofdm_tx tb_ofdm_rx tb_loopback

# =============================================================================
# Aggregate targets
# =============================================================================
all_ldpc: tb_barrel_shifter tb_min2 tb_cnu tb_vnu tb_top
	@echo "=== All LDPC testbenches completed ==="

all_channel: tb_fir_sparse tb_fir_dense32 tb_fir_dense64 tb_fir_dense128 tb_fir_dense256 \
             tb_fir_compare tb_awgn tb_channel_model
	@echo "=== All channel model testbenches completed ==="

all_ofdm_rx: tb_cp_removal tb_fft tb_demux tb_ch_est tb_eq tb_demap tb_frame tb_ofdm_rx
	@echo "=== All OFDM RX testbenches completed ==="

all_ofdm_tx: tb_encoder tb_mapper tb_cp_insert tb_ifft tb_mux tb_ofdm_tx
	@echo "=== All OFDM TX testbenches completed ==="

all_sync: tb_noise_est tb_sym_sync tb_cfo_corr
	@echo "=== All sync/estimation testbenches completed ==="

all_integration: tb_ofdm_tx tb_ofdm_rx tb_loopback
	@echo "=== All integration testbenches completed ==="

all: all_ldpc all_channel all_ofdm_rx all_ofdm_tx all_sync all_integration
	@echo ""
	@echo "============================================"
	@echo "All testbenches completed."
	@echo "============================================"

# =============================================================================
# Existing LDPC Testbenches
# =============================================================================
tb_barrel_shifter: tb_barrel_shifter.vvp
	$(VVP) $<

tb_barrel_shifter.vvp: $(TB_BARREL) $(RTL_BARREL)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_min2: tb_min2_finder.vvp
	$(VVP) $<

tb_min2_finder.vvp: $(TB_MIN2) $(RTL_MIN2)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_cnu: tb_check_node_unit.vvp
	$(VVP) $<

tb_check_node_unit.vvp: $(TB_CNU) $(RTL_CNU)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_vnu: tb_variable_node_unit.vvp
	$(VVP) $<

tb_variable_node_unit.vvp: $(TB_VNU) $(RTL_VNU)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_top: tb_ldpc_top.vvp
	$(VVP) $<

tb_ldpc_top.vvp: $(TB_LDPC_TOP) $(RTL_LDPC_ALL)
	$(IVERILOG) $(IVFLAGS) -o $@ $(RTL_LDPC_ALL) $(TB_LDPC_TOP)

# =============================================================================
# Channel Model Testbenches (Phase A)
# =============================================================================
tb_fir_sparse: tb_channel_fir_sparse.vvp
	$(VVP) $<

tb_channel_fir_sparse.vvp: $(TB_FIR_SP) $(RTL_FIR_SP)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_fir_dense32: tb_channel_fir_dense32.vvp
	$(VVP) $<

tb_channel_fir_dense32.vvp: $(TB_FIR_D32) $(RTL_FIR_D32)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_fir_dense64: tb_channel_fir_dense64.vvp
	$(VVP) $<

tb_channel_fir_dense64.vvp: $(TB_FIR_D64) $(RTL_FIR_D64)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_fir_dense128: tb_channel_fir_dense128.vvp
	$(VVP) $<

tb_channel_fir_dense128.vvp: $(TB_FIR_D128) $(RTL_FIR_D128)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_fir_dense256: tb_channel_fir_dense256.vvp
	$(VVP) $<

tb_channel_fir_dense256.vvp: $(TB_FIR_D256) $(RTL_FIR_D256)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_awgn: tb_awgn_generator.vvp
	$(VVP) $<

tb_awgn_generator.vvp: $(TB_AWGN) $(RTL_AWGN)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_channel_model: tb_channel_model_top.vvp
	$(VVP) $<

tb_channel_model_top.vvp: $(TB_CH_MODEL) $(RTL_CH_TOP)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# OFDM Receiver Testbenches (Phase B)
# =============================================================================
tb_cp_removal: tb_cp_removal.vvp
	$(VVP) $<

tb_cp_removal.vvp: $(TB_CP_REM) $(RTL_CP_REM)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_fft: tb_fft_64pt.vvp
	$(VVP) $<

tb_fft_64pt.vvp: $(TB_FFT) $(RTL_FFT)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_demux: tb_subcarrier_demux.vvp
	$(VVP) $<

tb_subcarrier_demux.vvp: $(TB_DEMUX) $(RTL_DEMUX)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_ch_est: tb_channel_estimator.vvp
	$(VVP) $<

tb_channel_estimator.vvp: $(TB_CH_EST) $(RTL_CH_EST)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_eq: tb_equalizer.vvp
	$(VVP) $<

tb_equalizer.vvp: $(TB_EQ) $(RTL_EQ)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_demap: tb_soft_demapper.vvp
	$(VVP) $<

tb_soft_demapper.vvp: $(TB_DEMAP) $(RTL_DEMAP)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_frame: tb_frame_controller.vvp
	$(VVP) $<

tb_frame_controller.vvp: $(TB_FRAME) $(RTL_FRAME)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# OFDM Transmitter Testbenches (Phase F)
# =============================================================================
tb_encoder: tb_ldpc_encoder.vvp
	$(VVP) $<

tb_ldpc_encoder.vvp: $(TB_ENCODER) $(RTL_ENCODER)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_mapper: tb_qam_mapper.vvp
	$(VVP) $<

tb_qam_mapper.vvp: $(TB_MAPPER) $(RTL_MAPPER)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_cp_insert: tb_cp_insertion.vvp
	$(VVP) $<

tb_cp_insertion.vvp: $(TB_CP_INS) $(RTL_CP_INS)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_ifft: tb_ifft_64pt.vvp
	$(VVP) $<

tb_ifft_64pt.vvp: $(TB_IFFT) $(RTL_IFFT)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_mux: tb_subcarrier_mux.vvp
	$(VVP) $<

tb_subcarrier_mux.vvp: $(TB_SUB_MUX) $(RTL_SUB_MUX)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Sync / Estimation Testbenches (Phase G)
# =============================================================================
tb_noise_est: tb_noise_estimator.vvp
	$(VVP) $<

tb_noise_estimator.vvp: $(TB_NOISE_EST) $(RTL_NOISE_EST)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_sym_sync: tb_symbol_sync.vvp
	$(VVP) $<

tb_symbol_sync.vvp: $(TB_SYM_SYNC) $(RTL_SYM_SYNC)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_cfo_corr: tb_cfo_corrector.vvp
	$(VVP) $<

tb_cfo_corrector.vvp: $(TB_CFO_CORR) $(RTL_CFO_CORR)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# FIR Comparison Testbench
# =============================================================================
RTL_FIR_ALL  := $(RTL_FIR_SP) $(RTL_FIR_D32) $(RTL_FIR_D64) $(RTL_FIR_D128) $(RTL_FIR_D256)

tb_fir_compare: tb_fir_compare.vvp
	$(VVP) $<

tb_fir_compare.vvp: $(TB_FIR_CMP) $(RTL_FIR_ALL)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Integration Testbenches
# =============================================================================
tb_ofdm_tx: tb_ofdm_tx_top.vvp
	$(VVP) $<

tb_ofdm_tx_top.vvp: $(TB_OFDM_TX) $(RTL_OFDM_TX)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

tb_ofdm_rx: tb_ofdm_rx_top.vvp
	$(VVP) $<

tb_ofdm_rx_top.vvp: $(TB_OFDM_RX) $(RTL_OFDM_RX)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

RTL_LOOPBACK_ALL := $(RTL_OFDM_TX) $(RTL_CH_TOP) $(RTL_OFDM_RX) $(RTL_LDPC_ALL) $(RTL_LOOPBACK)

tb_loopback: tb_ofdm_loopback.vvp
	$(VVP) $<

tb_ofdm_loopback.vvp: $(TB_LOOPBACK) $(RTL_LOOPBACK_ALL)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Verilator targets (lint check)
# =============================================================================
lint:
	$(VERILATOR) --lint-only -Wall $(RTL_LDPC_ALL)

# =============================================================================
# Clean
# =============================================================================
clean:
	rm -f *.vvp *.vcd *.fst
	rm -rf obj_dir

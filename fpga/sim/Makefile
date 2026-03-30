# =============================================================================
# Makefile — LDPC Decoder FPGA Simulation
# =============================================================================
# Supports Icarus Verilog (iverilog) and Verilator
#
# Targets:
#   make tb_barrel_shifter  — Run barrel shifter testbench
#   make tb_min2            — Run min2 finder testbench
#   make tb_cnu             — Run check node unit testbench
#   make tb_vnu             — Run variable node unit testbench
#   make tb_top             — Run top-level integration testbench
#   make all                — Run all testbenches
#   make clean              — Remove generated files
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

# RTL source files
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
RTL_TOP      := $(RTL_DIR)/ldpc_top.sv

# RTL_ALL: deduplicated list of all RTL sources (RTL_CNU already includes barrel/sign_xor/min2)
RTL_ALL := $(RTL_DIR)/barrel_shifter.sv \
           $(RTL_DIR)/sign_xor_tree.sv \
           $(RTL_DIR)/min2_finder.sv \
           $(RTL_DIR)/check_node_unit.sv \
           $(RTL_VNU) $(RTL_MSG_RAM) $(RTL_BM_ROM) $(RTL_ITER) $(RTL_SYNDROME) \
           $(RTL_LLR_BUF) $(RTL_OUT_BUF) $(RTL_TOP)

# Testbench files
TB_BARREL := $(TB_DIR)/tb_barrel_shifter.sv
TB_MIN2   := $(TB_DIR)/tb_min2_finder.sv
TB_CNU    := $(TB_DIR)/tb_check_node_unit.sv
TB_VNU    := $(TB_DIR)/tb_variable_node_unit.sv
TB_TOP    := $(TB_DIR)/tb_ldpc_top.sv

# =============================================================================
# Phony targets
# =============================================================================
.PHONY: all clean tb_barrel_shifter tb_min2 tb_cnu tb_vnu tb_top

all: tb_barrel_shifter tb_min2 tb_cnu tb_vnu tb_top
	@echo ""
	@echo "============================================"
	@echo "All testbenches completed."
	@echo "============================================"

# =============================================================================
# Barrel Shifter
# =============================================================================
tb_barrel_shifter: tb_barrel_shifter.vvp
	$(VVP) $<

tb_barrel_shifter.vvp: $(TB_BARREL) $(RTL_BARREL)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Min2 Finder
# =============================================================================
tb_min2: tb_min2_finder.vvp
	$(VVP) $<

tb_min2_finder.vvp: $(TB_MIN2) $(RTL_MIN2)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Check Node Unit
# =============================================================================
tb_cnu: tb_check_node_unit.vvp
	$(VVP) $<

tb_check_node_unit.vvp: $(TB_CNU) $(RTL_CNU)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Variable Node Unit
# =============================================================================
tb_vnu: tb_variable_node_unit.vvp
	$(VVP) $<

tb_variable_node_unit.vvp: $(TB_VNU) $(RTL_VNU)
	$(IVERILOG) $(IVFLAGS) -o $@ $^

# =============================================================================
# Top-Level Integration
# =============================================================================
tb_top: tb_ldpc_top.vvp
	$(VVP) $<

tb_ldpc_top.vvp: $(TB_TOP) $(RTL_ALL)
	$(IVERILOG) $(IVFLAGS) -o $@ $(RTL_ALL) $(TB_TOP)

# =============================================================================
# Verilator targets (lint check)
# =============================================================================
.PHONY: lint
lint:
	$(VERILATOR) --lint-only -Wall $(RTL_ALL)

# =============================================================================
# Clean
# =============================================================================
clean:
	rm -f *.vvp *.vcd *.fst
	rm -rf obj_dir

# ================================================================
# Copyright (c) 2016 Bluespec, Inc.  All Rights Reserved.
# This is an example Makefile for the examples in the standard
# Bluespec training session.

# You should only have to edit the variable definitions in the
# following section (or override them from the 'make' command line)

# You should also have performed your standard Bluespec setup, defining
# environment variables BLUESPECDIR, BLUESPEC_HOME and
# BLUESPEC_LICENSE_FILE, and placing $BLUESPEC_HOME/bin in your path
# so that you can invoke 'bsc', the Bluespec compiler.

# ================================================================
# Please modify the following for your installation and setup

# Directory for the specific example you are building
EG ?= 

# Directory containing the Bluespec Training distribution directory
DISTRO ?= ..

# Set this to the command that invokes your Verilog simulator
# VSIM ?= iverilog
VSIM ?= cvc
# VSIM ?= cver
# VSIM ?= vcsi
# VSIM ?= vcs
# VSIM ?= modelsim
# VSIM ?= ncsim
# VSIM ?= ncverilog

# ================================================================
# You should not have to change anything below this line - give it as flags in the running command

TOPFILE   = testbenches/sspi_simplex_tb.bsv
TOPMODULE = mkTest

# Subset of the SoC's -D list (hw/makefile.inc) needed by sspi.bsv and
# the AXI4/AXI4-Lite types it pulls in. -D simulate enables `logLevel; run the
# sim with e.g. `./mkTest_bsim +msspi +l0` to see the DUT's internal trace.
BSC_DEFINES = -D axi4_transactor_fifo_depth=2 -D axi4_internal_fifo_depth=2 \
              -D axi4_lite_transactor_fifo_depth=2 -D axi4_lite_internal_fifo_depth=2 \
              -D axi4_id_width=4 -D paddr=32 -D Addr_space=28 -D simulate

# Testbench configuration. Override on the command line, e.g.
#   make TB_DEFINES="-D TB_CPOL=1 -D TB_CPHA=0 -D TB_NBITS=8" all_bsim
# or use ./run_sspi_tb.sh which wraps this and saves logs per config.
TB_DEFINES ?=

# Source layout:
#   rtl/              RTL versions (sspi.bsv is the active one)
#   rtl/dependencies/ libraries the RTL imports, plus Logger.bsv which it
#                     `include`s (so that dir must be on BOTH paths)
#   testbenches/      testbench versions
#   .                 sspi.defines and sspi_tb_data.bsvi
# -p resolves `import`; -I resolves `include`; '+' keeps bsc's default path.
BSC_PATHS = -p rtl:rtl/dependencies:testbenches:.:+ \
            -I rtl -I rtl/dependencies -I testbenches -I .

BSC_COMP_FLAGS = $(BSC_DEFINES) $(TB_DEFINES) $(BSC_PATHS) -elab -keep-fires -aggressive-conditions -no-warn-action-shadowing -show-range-conflict
BSC_LINK_FLAGS = -keep-fires


.PHONY: help
help:
	@echo "Current settings"
	@echo "    BLUESPEC_LICENSE_FILE = " $(BLUESPEC_LICENSE_FILE)
	@echo "    BLUESPEC_HOME         = " $(BLUESPEC_HOME)
	@echo "    BLUESPECDIR           = " $(BLUESPECDIR)
	@echo ""
	@echo "    EG                    = " $(EG) " (redefine EG for another example)"
	@echo ""
	@echo "Targets for 'make':"
	@echo "    help                Print this information"
	@echo ""
	@echo "    Bluesim:"
	@echo "        compile         Compile for Bluesim"
	@echo "        link            Link a Bluesim executable"
	@echo "        simulate        Run the Bluesim simulation executable"
	@echo "                            (generates VCD file; remove -V flag to suppress VCD gen)"
	@echo "        all_bsim        Convenience for make compile link simulate"
	@echo ""
	@echo "    Verilog generation and Verilog sim:"
	@echo "        verilog         Compile for Verilog (Verilog files generated in verilog_dir/)"
	@echo "        v_link          Link a Verilog simulation executable"
	@echo "                            (current simulator:" $(VSIM) " (redefine VSIM for other Verilog simulators)"
	@echo "        v_simulate      Run the Verilog simulation executable"
	@echo "        all_vsim        Convenience for make verilog v_link v_simulate"
	@echo "                            (generates VCD file; remove +bscvcd flag to suppress VCD gen)"
	@echo ""
	@echo "    clean               Delete intermediate files in build_bsim/ and build_v/ dirs"
	@echo "    full_clean          Delete all but this Makefile"

# ----------------------------------------------------------------
# Bluesim compile/link/simulate

BSIM_DIRS = -simdir build_bsim -bdir build_bsim -info-dir build_bsim
BSIM_EXE = $(TOPMODULE)_bsim

.PHONY: all_bsim
all_bsim: full_clean  compile  link    simulate

build_bsim:
	mkdir  build_bsim


.PHONY: compile
compile: build_bsim
	@echo Compiling for Bluesim ...
	bsc -steps-max-intervals 20000 -u +RTS -K80M -RTS -sim $(BSIM_DIRS) $(BSC_COMP_FLAGS) -g $(TOPMODULE)  $(TOPFILE) 
	@echo Compiling for Bluesim finished

.PHONY: link
link:
	@echo Linking for Bluesim ...
	bsc -e $(TOPMODULE) -sim -o $(BSIM_EXE) $(BSIM_DIRS) $(BSC_LINK_FLAGS) 
	@echo Linking for Bluesim finished

.PHONY: simulate
simulate:
	@echo Bluesim simulation ...
	./$(BSIM_EXE)  -V
	@echo Bluesim simulation finished

# ----------------------------------------------------------------
# Verilog compile/link/sim

V_DIRS = -vdir verilog_dir -bdir build_v -info-dir build_v
VSIM_EXE = $(TOPMODULE)_vsim

.PHONY: all_vsim
all_vsim: full_clean  verilog  v_link  v_simulate

build_v:
	mkdir  build_v
verilog_dir:
	mkdir  verilog_dir

.PHONY: verilog
verilog: build_v  verilog_dir
	@echo Compiling for Verilog ...
	bsc -u -verilog $(V_DIRS) $(BSC_COMP_FLAGS) -g $(TOPMODULE)  $(TOPFILE)
	@echo Compiling for Verilog finished

.PHONY: v_link
v_link:  build_v  verilog_dir
	@echo Linking for Verilog sim ...
	bsc -e $(TOPMODULE) -verilog -o ./$(VSIM_EXE) $(V_DIRS) -vsim $(VSIM)  verilog_dir/$(TOPMODULE).v \
		$(DISTRO)/Example_Programs/Common/C_imports.c
	@echo Linking for Verilog sim finished

.PHONY: v_simulate
v_simulate:
	@echo Verilog simulation...
	./$(VSIM_EXE)  +bscvcd
	@echo Verilog simulation finished

# ----------------------------------------------------------------

.PHONY: clean
clean:
	rm -f  build_bsim/*  build_v/*    *~

.PHONY: full_clean
full_clean:
	rm -r -f  build_bsim  build_v  verilog_dir  *~
	rm -f  *$(TOPMODULE)*  *.vcd  *.bo  *.ba  out  out.so


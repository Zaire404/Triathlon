TOPNAME ?= tb_triathlon
NXDC_FILES = constr/top.nxdc
INC_PATH ?= vsrc vsrc/include
NPC_HOME ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
TRIATHLON_HOME ?= $(abspath $(NPC_HOME)/..)

VERILATOR = verilator
# VERILATOR_CFLAGS += -MMD --build -cc \
# 				-O3 --x-assign fast --x-initial fast --noassert --trace -sv
VERILATOR_CFLAGS += -MMD --build -cc \
				-O1 -j $(shell nproc) --x-assign fast --x-initial fast --noassert --trace -sv
VERILATOR_CFLAGS += --Wno-fatal --Wno-WIDTH

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

default: $(BIN)

LLVM_LIBS := $(shell llvm-config --libs 2>/dev/null)

$(shell mkdir -p $(BUILD_DIR))

# # constraint file
# SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
# $(SRC_AUTO_BIND): $(NXDC_FILES)
# 	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@

# project source

PKG_VSRCS = \
	$(abspath ./vsrc/include/config_pkg.sv) \
	$(abspath ./vsrc/include/test_config_pkg.sv) \
	$(abspath ./vsrc/include/build_config_pkg.sv) \
	$(abspath ./vsrc/include/global_config_pkg.sv) \
	$(abspath ./vsrc/include/riscv_pkg.sv) \
	$(abspath ./vsrc/include/decode_pkg.sv)

DESIGN_VSRCS = $(shell find $(abspath ./vsrc) \
	-path $(abspath ./vsrc/include) -prune -o \
	-path $(abspath ./vsrc/test) -prune -o \
	\( -name "*.sv" -o -name "*.v" \) -print)

TOP_SV = $(firstword $(wildcard \
	$(abspath ./vsrc/test/$(TOPNAME).sv) \
	$(abspath ./vsrc/$(TOPNAME).sv)))

SIM_MAIN ?= $(firstword $(wildcard \
	$(abspath ./csrc/npc_main.cpp) \
	$(abspath ./csrc/npc_main.cc) \
	$(abspath ./csrc/npc_main.c) \
	$(abspath ./csrc/sim_main.cpp) \
	$(abspath ./csrc/sim_main.cc) \
	$(abspath ./csrc/sim_main.c) \
	$(abspath ./csrc/main.cpp) \
	$(abspath ./csrc/main.cc) \
	$(abspath ./csrc/main.c)))
SIM_SRCS ?=

VSRCS = $(PKG_VSRCS) $(DESIGN_VSRCS) $(TOP_SV)
CSRCS = $(SIM_MAIN) $(SIM_SRCS) $(SRC_AUTO_BIND)

# # rules for NVBoard
# include $(NVBOARD_HOME)/scripts/nvboard.mk
DIFFTEST_SO ?= $(NPC_HOME)/ref/riscv32-nemu-interpreter-so
DIFFTEST ?= $(if $(wildcard $(DIFFTEST_SO)),-d $(DIFFTEST_SO),)

# rules for verilator
IMG ?=
ARGS ?=
NPC_EXE := $(strip $(ARGS) $(DIFFTEST) $(IMG))
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -I$(abspath ./include) -DTOP_NAME="\"V$(TOPNAME)\"" -g -std=c++17
LDFLAGS += -lreadline -ldl -pie $(LLVM_LIBS)

NEED_CHECKS := $(filter-out clean clean-all help,$(MAKECMDGOALS))
ifneq ($(NEED_CHECKS),)
  ifeq ($(strip $(TOP_SV)),)
    $(error TOPNAME=$(TOPNAME) not found. Expected vsrc/$(TOPNAME).sv or vsrc/test/$(TOPNAME).sv)
  endif
  ifeq ($(strip $(SIM_MAIN)),)
    $(error No simulator main found. Set SIM_MAIN=... or add csrc/npc_main.cpp)
  endif
else ifeq ($(MAKECMDGOALS),)
  ifeq ($(strip $(TOP_SV)),)
    $(error TOPNAME=$(TOPNAME) not found. Expected vsrc/$(TOPNAME).sv or vsrc/test/$(TOPNAME).sv)
  endif
  ifeq ($(strip $(SIM_MAIN)),)
    $(error No simulator main found. Set SIM_MAIN=... or add csrc/npc_main.cpp)
  endif
endif

$(BIN): $(VSRCS) $(CSRCS) $(NVBOARD_ARCHIVE)
# 	@rm -rf $(OBJ_DIR)
	$(VERILATOR) $(VERILATOR_CFLAGS) \
		--top-module $(TOPNAME) $^ \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

all: default
	@echo "Write this Makefile by your self."

sim: $(BIN)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	@echo $(INCFLAGS)
	@$^ $(NPC_EXE)

gdb: $(BIN)
	$(call git_commit, "debug RTL") # DO NOT REMOVE THIS LINE!!!
	gdb -s $(BIN) --args $(BIN) $(NPC_EXE)

clean:
	rm -rf $(BUILD_DIR)

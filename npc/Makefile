TOPNAME = cpu
INC_PATH ?= vsrc

VERILATOR = verilator
VERILATOR_CFLAGS += -MMD --build -cc  \
				-O3 --x-assign fast --x-initial fast --noassert --trace

BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN = $(BUILD_DIR)/$(TOPNAME)

default: $(BIN)

LLVM_LIBS := $(shell llvm-config --libs)

$(shell mkdir -p $(BUILD_DIR))

# project source

# 明确将 define.v 放在最前面
VSRCS_DEFINE = $(abspath ./vsrc/define.v)
# 找到 vsrc 目录下除 define.v 之外的所有 .v 文件
VSRCS_OTHERS = $(filter-out $(VSRCS_DEFINE), $(shell find $(abspath ./vsrc) -name "*.v"))
# 组合成最终的文件列表
VSRCS = $(VSRCS_DEFINE) $(VSRCS_OTHERS)

CSRCS = $(shell find $(abspath ./csrc) -name "*.c" -or -name "*.cc" -or -name "*.cpp")
CSRCS += $(SRC_AUTO_BIND)

DIFFTEST = -d $(TRIATHLON_HOME)/npc/ref/riscv32-nemu-interpreter-so

# rules for verilator
IMG ?= 
ARGS ?= 
NPC_EXE := $(ARGS) $(DIFFTEST) $(IMG)
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -I$(abspath ./include) -DTOP_NAME="\"V$(TOPNAME)\"" -g
LDFLAGS += -lreadline -ldl -pie $(LLVM_LIBS)

$(BIN): $(VSRCS) $(CSRCS)
	@rm -rf $(OBJ_DIR)
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

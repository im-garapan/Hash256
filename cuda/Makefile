# HASH256 GPU Miner - CUDA Build
# Usage:
#   make                      # build with ARCH=sm_86 (default)
#   make ARCH=sm_89           # override target arch (RTX 4000 series)
#   make clean

NVCC      ?= nvcc
ARCH      ?= sm_86
TARGET    ?= libhash256miner.so

# Use .dylib on macOS
UNAME_S := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME_S),Darwin)
    TARGET := libhash256miner.dylib
endif

NVCC_FLAGS ?= -O3 -arch=$(ARCH) \
              --compiler-options '-fPIC' -shared \
              -Xptxas -O3 --use_fast_math -maxrregcount=64 \
              -lineinfo

SRC := miner_kernel.cu
HDR := keccak256.cuh

.PHONY: all clean rebuild info

all: $(TARGET)

$(TARGET): $(SRC) $(HDR)
	$(NVCC) $(NVCC_FLAGS) -o $@ $(SRC)
	@echo ""
	@echo "  Built: $@ (ARCH=$(ARCH))"

clean:
	rm -f $(TARGET) *.o

rebuild: clean all

info:
	@echo "NVCC      = $(NVCC)"
	@echo "ARCH      = $(ARCH)"
	@echo "TARGET    = $(TARGET)"
	@echo "NVCC_FLAGS= $(NVCC_FLAGS)"

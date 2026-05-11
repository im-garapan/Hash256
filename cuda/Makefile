# HASH256 GPU Miner - CUDA Build (Optimized for full GPU utilization)
NVCC = nvcc
NVCC_FLAGS = -O3 -arch=sm_86 --compiler-options '-fPIC' -shared -Xptxas -O3 --use_fast_math -maxrregcount=64
TARGET = libhash256miner.so

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    TARGET = libhash256miner.dylib
endif

ifdef ARCH
    NVCC_FLAGS = -O3 -arch=$(ARCH) --compiler-options '-fPIC' -shared -Xptxas -O3 --use_fast_math -maxrregcount=64
endif

all: $(TARGET)

$(TARGET): miner_kernel.cu keccak256.cuh
	$(NVCC) $(NVCC_FLAGS) -o $(TARGET) miner_kernel.cu

clean:
	rm -f $(TARGET)

.PHONY: all clean

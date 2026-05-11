/**
 * HASH256 GPU Miner - CUDA Mining Kernel
 * Brute-forces nonces: keccak256(challenge || nonce) < target
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "keccak256.cuh"

struct MiningResult {
    uint8_t  nonce[32];
    uint8_t  hash[32];
    uint32_t found;
};

__device__ int compare_hash_lt_target(const uint8_t* hash, const uint8_t* target) {
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 0;
}

__global__ void mine_kernel(
    const uint8_t* challenge,
    const uint8_t* target,
    uint64_t start_nonce,
    MiningResult* result
) {
    uint64_t thread_id = blockIdx.x * (uint64_t)blockDim.x + threadIdx.x;
    uint64_t nonce = start_nonce + thread_id;

    if (result->found) return;

    uint8_t input[64];

    #pragma unroll
    for (int i = 0; i < 32; i++) {
        input[i] = challenge[i];
    }

    #pragma unroll
    for (int i = 0; i < 24; i++) {
        input[32 + i] = 0;
    }
    input[56] = (uint8_t)(nonce >> 56);
    input[57] = (uint8_t)(nonce >> 48);
    input[58] = (uint8_t)(nonce >> 40);
    input[59] = (uint8_t)(nonce >> 32);
    input[60] = (uint8_t)(nonce >> 24);
    input[61] = (uint8_t)(nonce >> 16);
    input[62] = (uint8_t)(nonce >> 8);
    input[63] = (uint8_t)(nonce);

    uint8_t hash[32];
    keccak256_64bytes(input, hash);

    if (compare_hash_lt_target(hash, target)) {
        uint32_t old = atomicCAS(&result->found, 0, 1);
        if (old == 0) {
            #pragma unroll
            for (int i = 0; i < 32; i++) {
                result->nonce[i] = input[32 + i];
                result->hash[i] = hash[i];
            }
        }
    }
}

extern "C" {

int mine_batch(
    const char* challenge_hex,
    const char* target_hex,
    uint64_t start_nonce,
    uint64_t batch_size,
    int threads_per_block,
    char* nonce_out,
    char* hash_out
) {
    uint8_t h_challenge[32];
    uint8_t h_target[32];

    for (int i = 0; i < 32; i++) {
        unsigned int byte_val;
        sscanf(challenge_hex + i * 2, "%02x", &byte_val);
        h_challenge[i] = (uint8_t)byte_val;
    }
    for (int i = 0; i < 32; i++) {
        unsigned int byte_val;
        sscanf(target_hex + i * 2, "%02x", &byte_val);
        h_target[i] = (uint8_t)byte_val;
    }

    uint8_t *d_challenge, *d_target;
    MiningResult *d_result;
    MiningResult h_result;
    memset(&h_result, 0, sizeof(MiningResult));

    cudaMalloc(&d_challenge, 32);
    cudaMalloc(&d_target, 32);
    cudaMalloc(&d_result, sizeof(MiningResult));

    cudaMemcpy(d_challenge, h_challenge, 32, cudaMemcpyHostToDevice);
    cudaMemcpy(d_target, h_target, 32, cudaMemcpyHostToDevice);
    cudaMemcpy(d_result, &h_result, sizeof(MiningResult), cudaMemcpyHostToDevice);

    if (threads_per_block <= 0) threads_per_block = 256;
    uint64_t num_blocks = (batch_size + threads_per_block - 1) / threads_per_block;

    // RTX 3090: 82 SMs, max 2048 threads/SM = 167,936 concurrent threads
    // Use grid-stride loop for large batches - no cap needed
    // CUDA max gridDim.x = 2^31-1, but use uint32 max for safety
    if (num_blocks > 2147483647ULL) num_blocks = 2147483647ULL;

    mine_kernel<<<(unsigned int)num_blocks, threads_per_block>>>(
        d_challenge, d_target, start_nonce, d_result
    );
    cudaDeviceSynchronize();

    cudaMemcpy(&h_result, d_result, sizeof(MiningResult), cudaMemcpyDeviceToHost);

    cudaFree(d_challenge);
    cudaFree(d_target);
    cudaFree(d_result);

    if (h_result.found) {
        for (int i = 0; i < 32; i++) {
            sprintf(nonce_out + i * 2, "%02x", h_result.nonce[i]);
            sprintf(hash_out + i * 2, "%02x", h_result.hash[i]);
        }
        nonce_out[64] = '\0';
        hash_out[64] = '\0';
        return 1;
    }

    return 0;
}

int get_gpu_info(char* info_out, int max_len) {
    int device_count = 0;
    cudaGetDeviceCount(&device_count);
    if (device_count == 0) {
        snprintf(info_out, max_len, "No CUDA devices found");
        return 0;
    }

    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    snprintf(info_out, max_len,
        "GPU: %s | Compute: %d.%d | SMs: %d | Clock: %d MHz | Memory: %lu MB",
        prop.name, prop.major, prop.minor,
        prop.multiProcessorCount,
        prop.clockRate / 1000,
        prop.totalGlobalMem / (1024 * 1024)
    );
    return device_count;
}

} // extern "C"

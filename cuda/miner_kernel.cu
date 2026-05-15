/**
 * HASH256 GPU Miner - CUDA Mining Kernel
 * Brute-forces nonces: keccak256(challenge || nonce) < target
 *
 * v3.1 optimizations:
 *   - Persistent device buffers (challenge/target/result) — alloc once.
 *   - set_job() uploads challenge+target once per epoch; mine_batch
 *     auto-skips re-upload when hex args are unchanged.
 *   - cudaMemset (4 bytes) instead of cudaMemcpy (sizeof(MiningResult))
 *     to reset the "found" flag every batch.
 *   - Fast inline hex parser/printer (no sscanf/sprintf per call).
 *   - cudaPeekAtLastError + cudaGetLastError after launch.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "keccak256.cuh"

struct MiningResult {
    uint32_t found;       // placed first so cudaMemset(0, 4) clears it
    uint8_t  nonce[32];
    uint8_t  hash[32];
};

__device__ __forceinline__ int compare_hash_lt_target(const uint8_t* hash, const uint8_t* target) {
    #pragma unroll
    for (int i = 0; i < 32; i++) {
        if (hash[i] < target[i]) return 1;
        if (hash[i] > target[i]) return 0;
    }
    return 0;
}

__global__ void mine_kernel(
    const uint8_t* __restrict__ challenge,
    const uint8_t* __restrict__ target,
    uint64_t start_nonce,
    MiningResult* __restrict__ result
) {
    uint64_t thread_id = blockIdx.x * (uint64_t)blockDim.x + threadIdx.x;
    uint64_t nonce = start_nonce + thread_id;

    // Early-out if another thread already solved this batch.
    if (result->found) return;

    uint8_t input[64];

    #pragma unroll
    for (int i = 0; i < 32; i++) input[i] = challenge[i];

    #pragma unroll
    for (int i = 0; i < 24; i++) input[32 + i] = 0;

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
        if (atomicCAS(&result->found, 0, 1) == 0) {
            #pragma unroll
            for (int i = 0; i < 32; i++) {
                result->nonce[i] = input[32 + i];
                result->hash[i] = hash[i];
            }
        }
    }
}

// ───────────────────────────────────────────────────────────────────────────
// Host helpers
// ───────────────────────────────────────────────────────────────────────────

static inline int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// Returns 1 on success, 0 on bad input.
static int hex_to_bytes(const char* hex, uint8_t* out, int out_len) {
    for (int i = 0; i < out_len; i++) {
        int hi = hex_nibble(hex[i * 2]);
        int lo = hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return 0;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return 1;
}

static void bytes_to_hex(const uint8_t* in, int in_len, char* out) {
    static const char H[] = "0123456789abcdef";
    for (int i = 0; i < in_len; i++) {
        out[i * 2]     = H[(in[i] >> 4) & 0xF];
        out[i * 2 + 1] = H[in[i] & 0xF];
    }
    out[in_len * 2] = '\0';
}

#define CUDA_CHECK(call) do {                                              \
    cudaError_t _e = (call);                                               \
    if (_e != cudaSuccess) {                                               \
        fprintf(stderr, "[CUDA] %s failed: %s\n", #call, cudaGetErrorString(_e)); \
        return -1;                                                         \
    }                                                                      \
} while (0)

// ───────────────────────────────────────────────────────────────────────────
// Persistent device state
// ───────────────────────────────────────────────────────────────────────────

static uint8_t       *d_challenge    = NULL;
static uint8_t       *d_target       = NULL;
static MiningResult  *d_result       = NULL;
static int            gpu_initialized = 0;

// Cached host-side job so we can detect "same job, skip re-upload".
static uint8_t  cached_challenge[32];
static uint8_t  cached_target[32];
static int      cached_challenge_valid = 0;
static int      cached_target_valid    = 0;

extern "C" {

int gpu_init(void) {
    if (gpu_initialized) return 0;
    CUDA_CHECK(cudaMalloc(&d_challenge, 32));
    CUDA_CHECK(cudaMalloc(&d_target,    32));
    CUDA_CHECK(cudaMalloc(&d_result,    sizeof(MiningResult)));
    gpu_initialized = 1;
    return 0;
}

void gpu_cleanup(void) {
    if (!gpu_initialized) return;
    cudaFree(d_challenge);
    cudaFree(d_target);
    cudaFree(d_result);
    d_challenge = d_target = NULL;
    d_result = NULL;
    gpu_initialized = 0;
    cached_challenge_valid = 0;
    cached_target_valid    = 0;
}

/**
 * Upload challenge + target once per epoch. Optional helper called by
 * Python; mine_batch() will also auto-cache when called with hex args.
 * Returns 0 on success, -1 on error.
 */
int set_job(const char* challenge_hex, const char* target_hex) {
    if (!gpu_initialized && gpu_init() != 0) return -1;

    uint8_t c[32], t[32];
    if (!hex_to_bytes(challenge_hex, c, 32)) return -1;
    if (!hex_to_bytes(target_hex,    t, 32)) return -1;

    if (!cached_challenge_valid || memcmp(c, cached_challenge, 32) != 0) {
        CUDA_CHECK(cudaMemcpy(d_challenge, c, 32, cudaMemcpyHostToDevice));
        memcpy(cached_challenge, c, 32);
        cached_challenge_valid = 1;
    }
    if (!cached_target_valid || memcmp(t, cached_target, 32) != 0) {
        CUDA_CHECK(cudaMemcpy(d_target, t, 32, cudaMemcpyHostToDevice));
        memcpy(cached_target, t, 32);
        cached_target_valid = 1;
    }
    return 0;
}

/**
 * Mine one batch. Returns 1 if a solution was found, 0 if not, -1 on error.
 */
int mine_batch(
    const char* challenge_hex,
    const char* target_hex,
    uint64_t start_nonce,
    uint64_t batch_size,
    int threads_per_block,
    char* nonce_out,
    char* hash_out
) {
    if (!gpu_initialized && gpu_init() != 0) return -1;

    // Auto-cache: only re-upload challenge/target when they actually change.
    if (set_job(challenge_hex, target_hex) != 0) return -1;

    // Reset only the 4-byte 'found' flag instead of the whole struct.
    CUDA_CHECK(cudaMemset(&d_result->found, 0, sizeof(uint32_t)));

    if (threads_per_block <= 0) threads_per_block = 256;
    uint64_t num_blocks = (batch_size + threads_per_block - 1) / threads_per_block;
    if (num_blocks > 2147483647ULL) num_blocks = 2147483647ULL;

    mine_kernel<<<(unsigned int)num_blocks, threads_per_block>>>(
        d_challenge, d_target, start_nonce, d_result
    );

    // Surface launch errors before sync (config errors, OOM, etc).
    cudaError_t le = cudaPeekAtLastError();
    if (le != cudaSuccess) {
        fprintf(stderr, "[CUDA] kernel launch failed: %s\n", cudaGetErrorString(le));
        return -1;
    }

    CUDA_CHECK(cudaDeviceSynchronize());

    MiningResult h_result;
    CUDA_CHECK(cudaMemcpy(&h_result, d_result, sizeof(MiningResult), cudaMemcpyDeviceToHost));

    if (h_result.found) {
        bytes_to_hex(h_result.nonce, 32, nonce_out);
        bytes_to_hex(h_result.hash,  32, hash_out);
        return 1;
    }
    return 0;
}

int get_gpu_info(char* info_out, int max_len) {
    int device_count = 0;
    cudaError_t e = cudaGetDeviceCount(&device_count);
    if (e != cudaSuccess || device_count == 0) {
        snprintf(info_out, max_len, "No CUDA devices found (%s)",
                 e != cudaSuccess ? cudaGetErrorString(e) : "count=0");
        return 0;
    }

    cudaDeviceProp prop;
    if (cudaGetDeviceProperties(&prop, 0) != cudaSuccess) {
        snprintf(info_out, max_len, "CUDA device 0 (props unavailable)");
        return device_count;
    }

    snprintf(info_out, max_len,
        "GPU: %s | Compute: %d.%d | SMs: %d | Memory: %lu MB",
        prop.name, prop.major, prop.minor,
        prop.multiProcessorCount,
        (unsigned long)(prop.totalGlobalMem / (1024 * 1024))
    );
    return device_count;
}

} // extern "C"

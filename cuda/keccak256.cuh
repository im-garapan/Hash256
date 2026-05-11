/**
 * HASH256 GPU Miner - Keccak256 CUDA Implementation
 * Optimized for mining: keccak256(challenge || nonce) < target
 */

#ifndef KECCAK256_CUH
#define KECCAK256_CUH

#include <cuda_runtime.h>
#include <stdint.h>

// Keccak-256 round constants
__device__ __constant__ uint64_t RC[24] = {
    0x0000000000000001ULL, 0x0000000000008082ULL,
    0x800000000000808aULL, 0x8000000080008000ULL,
    0x000000000000808bULL, 0x0000000080000001ULL,
    0x8000000080008081ULL, 0x8000000000008009ULL,
    0x000000000000008aULL, 0x0000000000000088ULL,
    0x0000000080008009ULL, 0x000000008000000aULL,
    0x000000008000808bULL, 0x800000000000008bULL,
    0x8000000000008089ULL, 0x8000000000008003ULL,
    0x8000000000008002ULL, 0x8000000000000080ULL,
    0x000000000000800aULL, 0x800000008000000aULL,
    0x8000000080008081ULL, 0x8000000000008080ULL,
    0x0000000080000001ULL, 0x8000000080008008ULL
};

// Rotation
__device__ __forceinline__ uint64_t rotl64(uint64_t x, int n) {
    return (x << n) | (x >> (64 - n));
}

// Keccak-f[1600] permutation
__device__ void keccak_f1600(uint64_t state[25]) {
    uint64_t C[5], D[5], B[25];

    #pragma unroll
    for (int round = 0; round < 24; round++) {
        // Theta
        C[0] = state[0] ^ state[5] ^ state[10] ^ state[15] ^ state[20];
        C[1] = state[1] ^ state[6] ^ state[11] ^ state[16] ^ state[21];
        C[2] = state[2] ^ state[7] ^ state[12] ^ state[17] ^ state[22];
        C[3] = state[3] ^ state[8] ^ state[13] ^ state[18] ^ state[23];
        C[4] = state[4] ^ state[9] ^ state[14] ^ state[19] ^ state[24];

        D[0] = C[4] ^ rotl64(C[1], 1);
        D[1] = C[0] ^ rotl64(C[2], 1);
        D[2] = C[1] ^ rotl64(C[3], 1);
        D[3] = C[2] ^ rotl64(C[4], 1);
        D[4] = C[3] ^ rotl64(C[0], 1);

        state[0]  ^= D[0]; state[5]  ^= D[0]; state[10] ^= D[0]; state[15] ^= D[0]; state[20] ^= D[0];
        state[1]  ^= D[1]; state[6]  ^= D[1]; state[11] ^= D[1]; state[16] ^= D[1]; state[21] ^= D[1];
        state[2]  ^= D[2]; state[7]  ^= D[2]; state[12] ^= D[2]; state[17] ^= D[2]; state[22] ^= D[2];
        state[3]  ^= D[3]; state[8]  ^= D[3]; state[13] ^= D[3]; state[18] ^= D[3]; state[23] ^= D[3];
        state[4]  ^= D[4]; state[9]  ^= D[4]; state[14] ^= D[4]; state[19] ^= D[4]; state[24] ^= D[4];

        // Rho + Pi
        B[0]  = state[0];
        B[10] = rotl64(state[1], 1);
        B[20] = rotl64(state[2], 62);
        B[5]  = rotl64(state[3], 28);
        B[15] = rotl64(state[4], 27);
        B[16] = rotl64(state[5], 36);
        B[1]  = rotl64(state[6], 44);
        B[11] = rotl64(state[7], 6);
        B[21] = rotl64(state[8], 55);
        B[6]  = rotl64(state[9], 20);
        B[7]  = rotl64(state[10], 3);
        B[17] = rotl64(state[11], 10);
        B[2]  = rotl64(state[12], 43);
        B[12] = rotl64(state[13], 25);
        B[22] = rotl64(state[14], 39);
        B[23] = rotl64(state[15], 41);
        B[8]  = rotl64(state[16], 45);
        B[18] = rotl64(state[17], 15);
        B[3]  = rotl64(state[18], 21);
        B[13] = rotl64(state[19], 8);
        B[14] = rotl64(state[20], 18);
        B[24] = rotl64(state[21], 2);
        B[9]  = rotl64(state[22], 61);
        B[19] = rotl64(state[23], 56);
        B[4]  = rotl64(state[24], 14);

        // Chi
        #pragma unroll 5
        for (int j = 0; j < 25; j += 5) {
            state[j + 0] = B[j + 0] ^ ((~B[j + 1]) & B[j + 2]);
            state[j + 1] = B[j + 1] ^ ((~B[j + 2]) & B[j + 3]);
            state[j + 2] = B[j + 2] ^ ((~B[j + 3]) & B[j + 4]);
            state[j + 3] = B[j + 3] ^ ((~B[j + 4]) & B[j + 0]);
            state[j + 4] = B[j + 4] ^ ((~B[j + 0]) & B[j + 1]);
        }

        // Iota
        state[0] ^= RC[round];
    }
}

/**
 * Compute keccak256 of exactly 64 bytes (challenge[32] || nonce[32])
 * Output: 32-byte hash
 */
__device__ void keccak256_64bytes(const uint8_t* input, uint8_t* output) {
    uint64_t state[25];

    // Zero state
    #pragma unroll
    for (int i = 0; i < 25; i++) {
        state[i] = 0;
    }

    // Absorb 64 bytes (8 uint64 words, little-endian) into state
    #pragma unroll
    for (int i = 0; i < 8; i++) {
        uint64_t word = 0;
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            word |= ((uint64_t)input[i * 8 + j]) << (j * 8);
        }
        state[i] ^= word;
    }

    // Padding for keccak256: domain separation 0x01, final bit 0x80
    state[8] ^= 0x01ULL;
    state[16] ^= 0x8000000000000000ULL;

    // Permute
    keccak_f1600(state);

    // Squeeze 32 bytes (4 uint64 words, little-endian)
    #pragma unroll
    for (int i = 0; i < 4; i++) {
        #pragma unroll
        for (int j = 0; j < 8; j++) {
            output[i * 8 + j] = (uint8_t)(state[i] >> (j * 8));
        }
    }
}

#endif // KECCAK256_CUH

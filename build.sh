#!/bin/bash
# HASH256 GPU Miner - quick build helper.
#
# Usage:
#   ./build.sh              # auto-detect arch from nvidia-smi (fallback sm_86)
#   ./build.sh sm_89        # force a specific arch
set -e

cd "$(dirname "$0")/cuda"

ARCH="${1:-}"
if [ -z "$ARCH" ]; then
    if command -v nvidia-smi >/dev/null 2>&1; then
        CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
             | head -1 | tr -d '. ')
        if [ -n "$CC" ]; then
            ARCH="sm_${CC}"
        fi
    fi
    ARCH="${ARCH:-sm_86}"
fi

echo "[build] ARCH=$ARCH"
make clean >/dev/null 2>&1 || true
make ARCH="$ARCH"

ls -lh libhash256miner.* 2>/dev/null || true
echo "[build] Done."

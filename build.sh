#!/bin/bash
# Quick build - pass GPU arch as argument
# Usage: ./build.sh sm_86
set -e
ARCH="${1:-sm_61}"
cd "$(dirname "$0")/cuda"
make clean 2>/dev/null || true
make ARCH="$ARCH"
echo "Done! Library: $(ls libhash256miner.* 2>/dev/null)"

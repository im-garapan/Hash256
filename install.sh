#!/bin/bash
# HASH256 GPU Miner - VPS One-Command Installer
# Usage: curl -sSL https://raw.githubusercontent.com/mrfunntastiic/artifacts/main/hash256-miner/install.sh | bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     HASH256 GPU Miner - VPS Auto-Installer      ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# Detect OS
if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else OS="unknown"; fi
echo -e "${GREEN}[+] OS: $OS${NC}"

# 1. NVIDIA Driver
echo -e "\n${YELLOW}[1/5] NVIDIA Drivers...${NC}"
if ! command -v nvidia-smi &>/dev/null; then
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq ubuntu-drivers-common
        sudo ubuntu-drivers autoinstall
    else
        echo -e "${RED}Install NVIDIA drivers manually: https://developer.nvidia.com/cuda-downloads${NC}"
    fi
else
    echo -e "${GREEN}  OK: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)${NC}"
fi

# 2. CUDA
echo -e "\n${YELLOW}[2/5] CUDA Toolkit...${NC}"
if ! command -v nvcc &>/dev/null; then
    if [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        sudo apt-get install -y -qq nvidia-cuda-toolkit build-essential
    else
        echo -e "${RED}Install CUDA: https://developer.nvidia.com/cuda-downloads${NC}"; exit 1
    fi
else
    echo -e "${GREEN}  OK: $(nvcc --version | grep release | awk '{print $5}' | tr -d ',')${NC}"
fi

# 3. Python
echo -e "\n${YELLOW}[3/5] Python3...${NC}"
if ! command -v python3 &>/dev/null; then
    sudo apt-get install -y -qq python3 python3-pip
else
    echo -e "${GREEN}  OK: $(python3 --version)${NC}"
fi

# 4. Clone & Build
echo -e "\n${YELLOW}[4/5] Setting up miner...${NC}"
INSTALL_DIR="$HOME/hash256-miner"

if [ -d "$INSTALL_DIR" ]; then
    cd "$INSTALL_DIR" && git pull --quiet 2>/dev/null || true
else
    git clone --depth 1 https://github.com/mrfunntastiic/artifacts.git /tmp/h256tmp 2>/dev/null
    cp -r /tmp/h256tmp/hash256-miner "$INSTALL_DIR"
    rm -rf /tmp/h256tmp
fi

cd "$INSTALL_DIR"
pip3 install -q web3 eth-account 2>/dev/null || pip install -q web3 eth-account

# Auto-detect GPU arch
GPU_ARCH="sm_61"
if command -v nvidia-smi &>/dev/null; then
    CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
    [ ! -z "$CC" ] && GPU_ARCH="sm_${CC}"
fi
echo -e "${GREEN}  Building CUDA (arch: $GPU_ARCH)...${NC}"
cd cuda && make clean 2>/dev/null; make ARCH="$GPU_ARCH"
cd "$INSTALL_DIR"

# 5. Config
echo -e "\n${YELLOW}[5/5] Config...${NC}"
[ ! -f .env ] && cp .env.example .env

echo -e "\n${CYAN}╔══════════════════════════════════════════════════╗"
echo "║            DONE! Edit .env then start mining     ║"
echo "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  nano ~/hash256-miner/.env"
echo "  cd ~/hash256-miner && python3 miner.py"
echo ""

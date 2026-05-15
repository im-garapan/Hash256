#!/bin/bash
# HASH256 GPU Miner - VPS One-Command Installer
# Usage: curl -sSL https://raw.githubusercontent.com/mrfunntastiic/artifacts/main/hash256-miner/install.sh | bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    else
        err "Need root or sudo for package installation."
        exit 1
    fi
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║     HASH256 GPU Miner - VPS Auto-Installer      ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── 0. Detect OS ────────────────────────────────────────────────────────
OS="unknown"
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS="${ID:-unknown}"
fi
ok "OS: $OS"

APT_OS=0
if [ "$OS" = "ubuntu" ] || [ "$OS" = "debian" ]; then
    APT_OS=1
fi

# ── 1. NVIDIA driver ────────────────────────────────────────────────────
log "[1/5] NVIDIA driver"
if ! command -v nvidia-smi >/dev/null 2>&1; then
    if [ "$APT_OS" = "1" ]; then
        $SUDO apt-get update -qq
        $SUDO apt-get install -y -qq ubuntu-drivers-common
        $SUDO ubuntu-drivers autoinstall || warn "ubuntu-drivers autoinstall failed; install manually."
        warn "A reboot is typically required after installing NVIDIA drivers."
    else
        err "Install NVIDIA drivers manually: https://developer.nvidia.com/cuda-downloads"
    fi
else
    ok "Detected: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
fi

# ── 2. CUDA toolkit ─────────────────────────────────────────────────────
log "[2/5] CUDA toolkit"
if ! command -v nvcc >/dev/null 2>&1; then
    if [ "$APT_OS" = "1" ]; then
        $SUDO apt-get install -y -qq nvidia-cuda-toolkit build-essential
    else
        err "Install CUDA: https://developer.nvidia.com/cuda-downloads"
        exit 1
    fi
else
    ok "Detected: $(nvcc --version | grep release | awk '{print $5}' | tr -d ',')"
fi

# ── 3. Python ───────────────────────────────────────────────────────────
log "[3/5] Python 3"
if ! command -v python3 >/dev/null 2>&1; then
    if [ "$APT_OS" = "1" ]; then
        $SUDO apt-get install -y -qq python3 python3-pip
    else
        err "Install Python 3 manually."
        exit 1
    fi
else
    ok "Detected: $(python3 --version)"
fi

# Choose pip command
PIP="pip3"
if ! command -v pip3 >/dev/null 2>&1; then
    if command -v pip >/dev/null 2>&1; then
        PIP="pip"
    else
        if [ "$APT_OS" = "1" ]; then
            $SUDO apt-get install -y -qq python3-pip
        fi
    fi
fi

# ── 4. Source + build ───────────────────────────────────────────────────
log "[4/5] Setting up miner"
INSTALL_DIR="${HASH256_INSTALL_DIR:-$HOME/hash256-miner}"

if [ -d "$INSTALL_DIR/.git" ]; then
    log "Existing repo at $INSTALL_DIR — pulling latest"
    git -C "$INSTALL_DIR" pull --quiet || warn "git pull failed; continuing with current checkout."
elif [ -d "$INSTALL_DIR" ]; then
    warn "Directory $INSTALL_DIR exists but is not a git repo — keeping as-is."
else
    TMPDIR=$(mktemp -d)
    log "Cloning into $TMPDIR ..."
    git clone --depth 1 https://github.com/mrfunntastiic/artifacts.git "$TMPDIR"
    cp -r "$TMPDIR/hash256-miner" "$INSTALL_DIR"
    rm -rf "$TMPDIR"
fi

cd "$INSTALL_DIR"

log "Installing Python dependencies"
if [ -f requirements.txt ]; then
    $PIP install -q -r requirements.txt
else
    $PIP install -q web3 eth-account
fi

# Auto-detect GPU compute capability for nvcc -arch
GPU_ARCH="sm_86"
if command -v nvidia-smi >/dev/null 2>&1; then
    CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
         | head -1 | tr -d '. ')
    if [ -n "$CC" ]; then
        GPU_ARCH="sm_${CC}"
    fi
fi

log "Building CUDA library (ARCH=$GPU_ARCH)"
( cd cuda && make clean >/dev/null 2>&1 || true; make ARCH="$GPU_ARCH" )

# ── 5. Config ───────────────────────────────────────────────────────────
log "[5/5] Config"
if [ ! -f .env ]; then
    cp .env.example .env
    ok "Created .env from .env.example"
else
    ok ".env already exists — left untouched"
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗"
echo "║   DONE! Edit .env then start mining             ║"
echo "╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo "  nano $INSTALL_DIR/.env        # set PRIVATE_KEY (and optionally TELEGRAM_*)"
echo "  cd $INSTALL_DIR && python3 miner.py"
echo ""

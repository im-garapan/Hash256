#!/bin/bash
# ============================================================================
# HASH256 GPU Miner - Full One-Shot Installer (Ubuntu/Debian)
#
# Covers EVERYTHING:
#   1.  Pre-flight checks (OS, root/sudo, internet)
#   2.  System packages (build tools, git, curl, screen)
#   3.  NVIDIA driver
#   4.  CUDA toolkit (nvcc)
#   5.  Python 3 + pip + venv
#   6.  Project sources (clone or use current dir)
#   7.  Python virtualenv + dependencies
#   8.  Build CUDA library (auto-detect ARCH)
#   9.  Interactive .env config (PRIVATE_KEY, RPC, Telegram)
#  10.  Optional Telegram test message
#  11.  Optional systemd service install
#  12.  Final health check + run instructions
#
# Each step prints a clear banner. On ANY failure, an ERR trap reports:
#   - which step failed
#   - the failing command
#   - line number in this script
#   - exit code
# Full log is mirrored to setup.log in the install directory.
#
# Usage:
#   bash setup.sh                       # interactive
#   bash setup.sh --yes                 # accept defaults, no prompts
#   bash setup.sh --skip-driver         # skip NVIDIA driver install
#   bash setup.sh --skip-cuda           # skip CUDA toolkit install
#   bash setup.sh --no-service          # don't ask about systemd
#   bash setup.sh --dir /opt/hash256    # custom install directory
# ============================================================================

set -Eeuo pipefail

# ─────────────────── Colors / output helpers ───────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BLUE=""; BOLD=""; NC=""
fi

CURRENT_STEP="<startup>"
STEPS_OK=()
STEPS_SKIPPED=()
STEPS_FAILED=()

banner() {
    echo ""
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}  $*${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }
step()  { CURRENT_STEP="$1"; banner "$1"; }

# ─────────────────── Error trap ────────────────────────────────────────────
on_error() {
    local exit_code=$?
    local lineno=${1:-?}
    local cmd=${2:-?}
    echo ""
    echo -e "${RED}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}║                    INSTALLATION FAILED                       ║${NC}"
    echo -e "${RED}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
    err "Step      : ${BOLD}${CURRENT_STEP}${NC}"
    err "Line      : ${lineno}"
    err "Command   : ${cmd}"
    err "Exit code : ${exit_code}"
    echo ""
    err "Common causes:"
    case "$CURRENT_STEP" in
        *"NVIDIA driver"*)
            echo "  • Headless server: try 'sudo ubuntu-drivers list' to choose a specific driver"
            echo "  • Secure Boot enabled: disable in BIOS or enroll MOK"
            echo "  • Existing nouveau driver: 'sudo apt purge nouveau-*' then reboot"
            ;;
        *"CUDA"*)
            echo "  • Package not in apt repo: install from https://developer.nvidia.com/cuda-downloads"
            echo "  • PATH missing nvcc: add '/usr/local/cuda/bin' to PATH"
            echo "  • Disk full: 'df -h' and free up space"
            ;;
        *"Python"*|*"venv"*|*"dependencies"*)
            echo "  • PEP 668 'externally-managed' on Ubuntu 23+: handled via venv (try re-running)"
            echo "  • Network blocked: configure pip mirror or proxy"
            echo "  • python3-venv missing: 'sudo apt install python3-venv'"
            ;;
        *"CUDA library"*|*"Build"*)
            echo "  • Wrong ARCH: pass --arch sm_XX or run 'nvidia-smi --query-gpu=compute_cap'"
            echo "  • nvcc missing: see CUDA step above"
            echo "  • g++ too new for nvcc: 'sudo apt install gcc-12 g++-12' and retry"
            ;;
        *"clone"*|*"sources"*)
            echo "  • Network/firewall blocking github.com"
            echo "  • Run in an existing checkout: 'cd <dir> && bash setup.sh --dir .'"
            ;;
        *"systemd"*)
            echo "  • Not running on a systemd host (containers, WSL1)"
            echo "  • Use --no-service to skip"
            ;;
    esac
    echo ""
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        err "Last 25 lines of log ($LOG_FILE):"
        tail -n 25 "$LOG_FILE" | sed 's/^/    /'
    fi
    STEPS_FAILED+=("$CURRENT_STEP")
    print_summary
    exit "$exit_code"
}
trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR

print_summary() {
    echo ""
    banner "Summary"
    if [ ${#STEPS_OK[@]} -gt 0 ]; then
        echo -e "${GREEN}OK     :${NC}"
        for s in "${STEPS_OK[@]}";      do echo "  ✓ $s"; done
    fi
    if [ ${#STEPS_SKIPPED[@]} -gt 0 ]; then
        echo -e "${YELLOW}Skipped:${NC}"
        for s in "${STEPS_SKIPPED[@]}"; do echo "  - $s"; done
    fi
    if [ ${#STEPS_FAILED[@]} -gt 0 ]; then
        echo -e "${RED}Failed :${NC}"
        for s in "${STEPS_FAILED[@]}";  do echo "  ✗ $s"; done
    fi
}
mark_ok()      { STEPS_OK+=("$CURRENT_STEP"); }
mark_skipped() { STEPS_SKIPPED+=("$CURRENT_STEP — $1"); }

# ─────────────────── Args ──────────────────────────────────────────────────
ASSUME_YES=0
SKIP_DRIVER=0
SKIP_CUDA=0
NO_SERVICE=0
INSTALL_DIR_ARG=""
ARCH_OVERRIDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)         ASSUME_YES=1 ;;
        --skip-driver)    SKIP_DRIVER=1 ;;
        --skip-cuda)      SKIP_CUDA=1 ;;
        --no-service)     NO_SERVICE=1 ;;
        --dir)            INSTALL_DIR_ARG="$2"; shift ;;
        --arch)           ARCH_OVERRIDE="$2"; shift ;;
        -h|--help)
            sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) err "Unknown arg: $1"; exit 2 ;;
    esac
    shift
done

prompt_yes_no() {
    local q="$1" default="${2:-y}" reply
    if [ "$ASSUME_YES" = "1" ]; then echo "$default"; return 0; fi
    read -r -p "$q [Y/n] " reply || reply=""
    reply="${reply:-$default}"
    case "$reply" in y|Y|yes|YES) echo y ;; *) echo n ;; esac
}

prompt_value() {
    local q="$1" default="$2" reply
    if [ "$ASSUME_YES" = "1" ]; then echo "$default"; return 0; fi
    if [ -n "$default" ]; then
        read -r -p "$q [$default]: " reply || reply=""
        echo "${reply:-$default}"
    else
        read -r -p "$q: " reply || reply=""
        echo "$reply"
    fi
}

prompt_secret() {
    local q="$1" reply
    if [ "$ASSUME_YES" = "1" ]; then echo ""; return 0; fi
    read -r -s -p "$q: " reply || reply=""
    echo ""
    echo "$reply"
}

# ─────────────────── Step 0: pre-flight ────────────────────────────────────
step "Step 0/12 — Pre-flight checks"

# OS
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-?}"
else
    OS_ID="unknown"; OS_VER="?"
fi
info "OS: $OS_ID $OS_VER"
case "$OS_ID" in
    ubuntu|debian) ok "Supported distribution detected." ;;
    *) warn "Untested distribution. Script targets Ubuntu/Debian. Continuing..." ;;
esac

# sudo
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
        info "Using sudo for privileged commands."
    else
        err "Not root and sudo missing. Install sudo or run as root."
        exit 1
    fi
else
    ok "Running as root."
fi

# Internet
if ! curl -fsSL --max-time 8 https://1.1.1.1 >/dev/null 2>&1 \
   && ! curl -fsSL --max-time 8 https://github.com >/dev/null 2>&1; then
    err "No internet connectivity. Aborting."
    exit 1
fi
ok "Internet connectivity OK."

# Disk space (rough: 5 GB free in $HOME)
FREE_KB=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
if [ "${FREE_KB:-0}" -lt 5000000 ]; then
    warn "Less than ~5 GB free in \$HOME. CUDA toolkit needs ~3 GB."
else
    ok "Disk space OK ($((FREE_KB / 1024)) MB free in \$HOME)."
fi

mark_ok

# ─────────────────── Resolve script source dir ─────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────── Step 1: install dir + log ─────────────────────────────
step "Step 1/12 — Install directory"

if [ -n "$INSTALL_DIR_ARG" ]; then
    INSTALL_DIR="$(cd "$INSTALL_DIR_ARG" 2>/dev/null && pwd || echo "$INSTALL_DIR_ARG")"
elif [ -f "$SCRIPT_DIR/miner.py" ]; then
    INSTALL_DIR="$SCRIPT_DIR"
    info "Using current checkout: $INSTALL_DIR"
else
    DEFAULT_DIR="$HOME/hash256-miner"
    INSTALL_DIR="$(prompt_value "Install directory" "$DEFAULT_DIR")"
fi

mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
LOG_FILE="$INSTALL_DIR/setup.log"
: > "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
ok "Install dir: $INSTALL_DIR"
ok "Log file:    $LOG_FILE"
mark_ok

# ─────────────────── Step 2: base packages ─────────────────────────────────
step "Step 2/12 — Base system packages"

if command -v apt-get >/dev/null 2>&1; then
    info "Refreshing apt cache..."
    $SUDO apt-get update -qq
    info "Installing base packages..."
    $SUDO apt-get install -y -qq \
        build-essential git curl ca-certificates \
        screen pciutils
    ok "Base packages installed."
    mark_ok
else
    warn "apt-get not found; skipping base package install."
    mark_skipped "apt-get unavailable"
fi

# ─────────────────── Step 3: NVIDIA driver ─────────────────────────────────
step "Step 3/12 — NVIDIA driver"

if [ "$SKIP_DRIVER" = "1" ]; then
    warn "--skip-driver set; skipping."
    mark_skipped "user --skip-driver"
elif command -v nvidia-smi >/dev/null 2>&1; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "?")
    ok "Driver already present. GPU: $GPU_NAME"
    mark_ok
else
    if ! lspci | grep -i nvidia >/dev/null 2>&1; then
        warn "No NVIDIA GPU detected via lspci. CPU fallback will be used."
        mark_skipped "no NVIDIA GPU"
    elif [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]; then
        info "Installing ubuntu-drivers-common..."
        $SUDO apt-get install -y -qq ubuntu-drivers-common
        info "Running 'ubuntu-drivers autoinstall' (this can take several minutes)..."
        $SUDO ubuntu-drivers autoinstall
        warn "A reboot is typically required for the new driver to load."
        warn "After reboot, re-run: bash $SCRIPT_DIR/setup.sh --dir $INSTALL_DIR"
        mark_ok
    else
        err "Auto-install only supported on Ubuntu/Debian."
        err "Install manually: https://developer.nvidia.com/cuda-downloads"
        exit 1
    fi
fi

# ─────────────────── Step 4: CUDA toolkit ──────────────────────────────────
step "Step 4/12 — CUDA toolkit (nvcc)"

if [ "$SKIP_CUDA" = "1" ]; then
    warn "--skip-cuda set; skipping."
    mark_skipped "user --skip-cuda"
elif command -v nvcc >/dev/null 2>&1; then
    NVCC_VER=$(nvcc --version | grep release | awk '{print $5}' | tr -d ',')
    ok "nvcc already installed (release $NVCC_VER)."
    mark_ok
else
    if [ "$OS_ID" = "ubuntu" ] || [ "$OS_ID" = "debian" ]; then
        info "Installing nvidia-cuda-toolkit (this is large, ~2-3 GB)..."
        $SUDO apt-get install -y -qq nvidia-cuda-toolkit
        if command -v nvcc >/dev/null 2>&1; then
            ok "nvcc installed: $(nvcc --version | grep release | awk '{print $5}' | tr -d ',')"
            mark_ok
        else
            err "nvcc still missing after apt install. Install from https://developer.nvidia.com/cuda-downloads"
            exit 1
        fi
    else
        err "Manual install required: https://developer.nvidia.com/cuda-downloads"
        exit 1
    fi
fi

# ─────────────────── Step 5: Python 3 + venv ───────────────────────────────
step "Step 5/12 — Python 3 + venv"

if ! command -v python3 >/dev/null 2>&1; then
    info "Installing Python 3..."
    $SUDO apt-get install -y -qq python3 python3-pip python3-venv
fi

if ! python3 -c "import venv" >/dev/null 2>&1; then
    info "Installing python3-venv..."
    $SUDO apt-get install -y -qq python3-venv || true
fi

PY_VER=$(python3 --version 2>&1 || echo "?")
ok "Python: $PY_VER"
mark_ok

# ─────────────────── Step 6: project sources ───────────────────────────────
step "Step 6/12 — Project sources"

if [ -f "$INSTALL_DIR/miner.py" ] && [ -d "$INSTALL_DIR/cuda" ]; then
    ok "Project files already present in $INSTALL_DIR."
    mark_ok
elif [ -f "$SCRIPT_DIR/miner.py" ] && [ -d "$SCRIPT_DIR/cuda" ] && [ "$SCRIPT_DIR" != "$INSTALL_DIR" ]; then
    info "Copying project from $SCRIPT_DIR to $INSTALL_DIR ..."
    cp -r "$SCRIPT_DIR"/. "$INSTALL_DIR"/
    ok "Sources copied."
    mark_ok
else
    info "Cloning project from GitHub..."
    TMPDIR=$(mktemp -d)
    git clone --depth 1 https://github.com/mrfunntastiic/artifacts.git "$TMPDIR"
    if [ -d "$TMPDIR/hash256-miner" ]; then
        cp -r "$TMPDIR/hash256-miner/." "$INSTALL_DIR/"
    else
        err "Cloned repo missing hash256-miner/ folder."
        exit 1
    fi
    rm -rf "$TMPDIR"
    ok "Sources fetched."
    mark_ok
fi

# Validate expected files
for f in miner.py requirements.txt cuda/Makefile cuda/miner_kernel.cu cuda/keccak256.cuh; do
    if [ ! -f "$INSTALL_DIR/$f" ]; then
        err "Missing required file: $f"
        exit 1
    fi
done

# ─────────────────── Step 7: Python venv + dependencies ────────────────────
step "Step 7/12 — Python virtualenv + dependencies"

VENV_DIR="$INSTALL_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
    info "Creating virtualenv at $VENV_DIR ..."
    python3 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

info "Upgrading pip in venv..."
pip install --quiet --upgrade pip wheel

info "Installing Python dependencies from requirements.txt ..."
pip install --quiet -r "$INSTALL_DIR/requirements.txt"
ok "Dependencies installed in venv."
mark_ok

# ─────────────────── Step 8: Build CUDA library ────────────────────────────
step "Step 8/12 — Build CUDA library"

if [ ! -f "$INSTALL_DIR/cuda/Makefile" ]; then
    err "cuda/Makefile missing."
    exit 1
fi

if [ -n "$ARCH_OVERRIDE" ]; then
    GPU_ARCH="$ARCH_OVERRIDE"
elif command -v nvidia-smi >/dev/null 2>&1; then
    CC=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
         | head -1 | tr -d '. ' || true)
    if [ -n "${CC:-}" ]; then
        GPU_ARCH="sm_${CC}"
    else
        GPU_ARCH="sm_86"
    fi
else
    GPU_ARCH="sm_86"
fi
info "Target architecture: $GPU_ARCH"

if command -v nvcc >/dev/null 2>&1; then
    ( cd "$INSTALL_DIR/cuda" && make clean >/dev/null 2>&1 || true )
    ( cd "$INSTALL_DIR/cuda" && make ARCH="$GPU_ARCH" )
    if [ -f "$INSTALL_DIR/cuda/libhash256miner.so" ]; then
        ok "Built: cuda/libhash256miner.so"
        mark_ok
    else
        err "Build completed but library not found."
        exit 1
    fi
else
    warn "nvcc not available; skipping CUDA build (CPU fallback will be used)."
    mark_skipped "nvcc unavailable"
fi

# ─────────────────── Step 9: .env config ───────────────────────────────────
step "Step 9/12 — Configure .env"

ENV_FILE="$INSTALL_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    cp "$INSTALL_DIR/.env.example" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Created $ENV_FILE from template (chmod 600)."
else
    ok ".env already exists."
fi

# Helper: set or replace KEY=VALUE in .env (idempotent)
env_set() {
    local key="$1" value="$2" file="$ENV_FILE"
    if grep -q "^${key}=" "$file"; then
        # Replace using a delimiter unlikely to appear in URLs/keys
        python3 - "$key" "$value" "$file" <<'PY'
import re, sys
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    text = f.read()
text = re.sub(rf"(?m)^{re.escape(key)}=.*$", f"{key}={value}", text)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$file"
    fi
}

if [ "$ASSUME_YES" = "0" ]; then
    echo ""
    info "Configure your wallet and notifications (press Enter to keep current)."

    CUR_PK=$(grep -E '^PRIVATE_KEY=' "$ENV_FILE" | cut -d= -f2- || true)
    NEW_PK=$(prompt_secret "PRIVATE_KEY (hidden, leave empty to keep current)")
    if [ -n "$NEW_PK" ]; then
        env_set PRIVATE_KEY "$NEW_PK"
        ok "PRIVATE_KEY updated."
    elif [ -z "$CUR_PK" ] || [ "$CUR_PK" = "your_private_key_here" ]; then
        warn "PRIVATE_KEY not set. You must edit .env before running the miner."
    else
        ok "Keeping existing PRIVATE_KEY."
    fi

    CUR_RPC=$(grep -E '^RPC_URL=' "$ENV_FILE" | cut -d= -f2- || true)
    NEW_RPC=$(prompt_value "RPC_URL" "${CUR_RPC:-https://eth.llamarpc.com}")
    env_set RPC_URL "$NEW_RPC"
    ok "RPC_URL set to $NEW_RPC"

    if [ "$(prompt_yes_no "Configure Telegram notifications now?" n)" = "y" ]; then
        CUR_TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)
        NEW_TOKEN=$(prompt_value "TELEGRAM_BOT_TOKEN" "$CUR_TOKEN")
        env_set TELEGRAM_BOT_TOKEN "$NEW_TOKEN"

        CUR_CHAT=$(grep -E '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2- || true)
        NEW_CHAT=$(prompt_value "TELEGRAM_CHAT_ID" "$CUR_CHAT")
        env_set TELEGRAM_CHAT_ID "$NEW_CHAT"
        ok "Telegram credentials saved."
    fi
else
    info "--yes mode: leaving .env untouched."
fi
mark_ok

# ─────────────────── Step 10: Telegram test ────────────────────────────────
step "Step 10/12 — Telegram test message (optional)"

# Source .env to grab values
TG_TOKEN=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d= -f2- || true)
TG_CHAT=$(grep -E '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2- || true)

if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT" ]; then
    warn "Telegram not configured — skipping."
    mark_skipped "TELEGRAM_BOT_TOKEN/CHAT_ID empty"
elif [ "$(prompt_yes_no "Send a test message to Telegram now?" y)" = "y" ]; then
    info "POST https://api.telegram.org/bot***/sendMessage ..."
    HTTP_CODE=$(curl -s -o /tmp/tg.out -w "%{http_code}" \
        --max-time 10 \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "text=✅ HASH256 miner setup complete on $(hostname)" \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" || echo "000")
    if [ "$HTTP_CODE" = "200" ]; then
        ok "Telegram test message sent."
        mark_ok
    else
        warn "Telegram returned HTTP $HTTP_CODE. Response:"
        sed 's/^/    /' /tmp/tg.out || true
        warn "Check token/chat id; mining will still proceed."
        mark_skipped "telegram test failed (HTTP $HTTP_CODE)"
    fi
    rm -f /tmp/tg.out
else
    mark_skipped "user declined"
fi

# ─────────────────── Step 11: systemd service (optional) ───────────────────
step "Step 11/12 — systemd service (optional)"

if [ "$NO_SERVICE" = "1" ]; then
    mark_skipped "user --no-service"
elif ! command -v systemctl >/dev/null 2>&1 || ! [ -d /etc/systemd/system ]; then
    warn "systemd not available."
    mark_skipped "no systemd"
elif [ "$(prompt_yes_no "Install systemd service for auto-start on boot?" n)" = "y" ]; then
    SERVICE_NAME="hash256-miner.service"
    SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
    USER_NAME=$(id -un)

    info "Writing $SERVICE_PATH (User=$USER_NAME)..."
    $SUDO tee "$SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=HASH256 GPU Miner
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/miner.py
Restart=on-failure
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$SERVICE_NAME" >/dev/null
    ok "Service installed and enabled (not started yet)."
    info "  Start now : sudo systemctl start hash256-miner"
    info "  View logs : sudo journalctl -fu hash256-miner"
    mark_ok
else
    mark_skipped "user declined"
fi

# ─────────────────── Step 12: health check ─────────────────────────────────
step "Step 12/12 — Final health check"

# 1. nvidia-smi
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    ok "GPU detected: $GPU_NAME"
else
    warn "nvidia-smi not on PATH (a reboot may be required after driver install)."
fi

# 2. nvcc
if command -v nvcc >/dev/null 2>&1; then
    ok "nvcc: $(nvcc --version | grep release | awk '{print $5}' | tr -d ',')"
else
    warn "nvcc not found — CPU fallback only."
fi

# 3. CUDA library
if [ -f "$INSTALL_DIR/cuda/libhash256miner.so" ]; then
    ok "Library: cuda/libhash256miner.so ($(stat -c%s "$INSTALL_DIR/cuda/libhash256miner.so") bytes)"
else
    warn "cuda/libhash256miner.so missing — CPU fallback only."
fi

# 4. Python imports
if "$VENV_DIR/bin/python" -c "import web3, eth_account; print('  web3:', web3.__version__)" 2>/dev/null; then
    ok "Python deps importable."
else
    err "Python deps not importable in venv."
    exit 1
fi

# 5. Quick miner.py --help (also catches syntax errors)
if "$VENV_DIR/bin/python" "$INSTALL_DIR/miner.py" --help >/dev/null 2>&1; then
    ok "miner.py loads correctly."
else
    err "miner.py failed to load. Inspect with:"
    err "  $VENV_DIR/bin/python $INSTALL_DIR/miner.py --help"
    exit 1
fi

# 6. .env sanity
PK_PRESENT=$(grep -E '^PRIVATE_KEY=' "$ENV_FILE" | cut -d= -f2- || true)
if [ -z "$PK_PRESENT" ] || [ "$PK_PRESENT" = "your_private_key_here" ]; then
    warn "PRIVATE_KEY is not set in .env. Edit it before starting:"
    warn "  nano $ENV_FILE"
fi

mark_ok

# ─────────────────── Done ──────────────────────────────────────────────────
print_summary

echo ""
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║                     INSTALLATION COMPLETE                    ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Install dir : $INSTALL_DIR"
echo "  Venv        : $VENV_DIR"
echo "  Log         : $LOG_FILE"
echo ""
echo -e "${BOLD}Run the miner:${NC}"
echo ""
echo "  cd $INSTALL_DIR"
echo "  source .venv/bin/activate"
echo "  python miner.py"
echo ""
echo -e "${BOLD}Or run in background (screen):${NC}"
echo ""
echo "  screen -dmS miner bash -c 'cd $INSTALL_DIR && source .venv/bin/activate && python miner.py'"
echo "  screen -r miner    # to attach"
echo ""
if systemctl list-unit-files 2>/dev/null | grep -q '^hash256-miner.service'; then
    echo -e "${BOLD}Or via systemd:${NC}"
    echo ""
    echo "  sudo systemctl start hash256-miner"
    echo "  sudo journalctl -fu hash256-miner"
    echo ""
fi

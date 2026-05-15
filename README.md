# HASH256 GPU Miner

GPU-accelerated CLI miner for [HASH token](https://hash256.org) on Ethereum
Mainnet. Written in CUDA (keccak-256 brute force) + Python (RPC + tx
submission). Works on any NVIDIA GPU from Pascal (sm_61) through Blackwell
(sm_120). Auto-tunes batch size per GPU. Optional Telegram notifications.

**Contract:** [`0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc`](https://etherscan.io/token/0xac7b5d06fa1e77d08aea40d46cb7c5923a87a0cc)

---

## How It Works

```
1. challenge  = contract.getChallenge(walletAddress)
2. difficulty = contract.currentDifficulty()
3. GPU brute-forces a nonce where:
       keccak256(challenge || nonce) < difficulty
4. Submit:    contract.mine(nonce)
5. Earn HASH (100 HASH/mint at Era 0). Repeat.
```

Each miner gets its own challenge from the contract, so you do not compete
on the *same* nonce search space — but you still race other miners to be
the first to land a `mine()` tx in the next block.

---

## Requirements

| | |
|---|---|
| OS         | Ubuntu 20.04 / 22.04 / 24.04 (or Debian 11+) |
| GPU        | NVIDIA, compute cap ≥ 6.1 (GTX 10xx and newer) |
| RAM        | 1 GB free |
| Disk       | ~5 GB (CUDA toolkit is the bulk) |
| Wallet     | Funded with ETH for gas (~$1-5 per mint) |

CPU-only mode exists but is **only useful for testing**. It is roughly
10,000× slower than a mid-range GPU and has no realistic chance of winning
a block in competitive mining.

---

## Install — Recommended (one command)

On a fresh Ubuntu/Debian VPS:

```bash
git clone https://github.com/im-garapan/Hash256.git ~/hash256-miner
cd ~/hash256-miner
bash setup.sh
```

`setup.sh` is a self-contained installer that handles everything in one
shot:

| Step | What it does |
|------|--------------|
| 0    | Pre-flight (OS, sudo, internet, disk) |
| 1    | Pick install dir, mirror logs to `setup.log` |
| 2    | `build-essential`, git, curl, screen |
| 3    | NVIDIA driver (via `ubuntu-drivers autoinstall`) |
| 4    | CUDA toolkit (`nvcc`) |
| 5    | Python 3 + venv |
| 6    | Project sources (existing or fresh clone) |
| 7    | Create `.venv` and install `requirements.txt` |
| 8    | Build CUDA library with auto-detected `-arch=sm_*` |
| 9    | Interactive `.env` wizard (PRIVATE_KEY hidden, RPC, Telegram) |
| 10   | Send a test message to Telegram (optional) |
| 11   | Install systemd service (optional) |
| 12   | Health check (deps importable, miner.py loads, .env sane) |

If anything fails the script prints a banner with the **failed step,
command, line number, exit code**, the last 25 lines of the log, and
contextual hints for that step. Full log lives in `setup.log`.

### Useful flags

```bash
bash setup.sh --yes              # non-interactive defaults
bash setup.sh --skip-driver      # NVIDIA driver already installed
bash setup.sh --skip-cuda        # nvcc already installed
bash setup.sh --no-service       # do not prompt for systemd
bash setup.sh --dir /opt/hash256 # custom install directory
bash setup.sh --arch sm_89       # force a specific CUDA arch
```

> If `setup.sh` installs the NVIDIA driver from scratch, **reboot first**,
> then re-run `bash setup.sh --dir <dir>` to continue with the CUDA build.

---

## Install — Manual (if you prefer step-by-step)

<details>
<summary>Click to expand</summary>

```bash
# 1. System packages
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential git python3 python3-pip python3-venv screen

# 2. NVIDIA driver
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers autoinstall
sudo reboot         # then come back

# 3. CUDA toolkit
sudo apt install -y nvidia-cuda-toolkit
nvcc --version       # verify

# 4. Project + venv
git clone https://github.com/im-garapan/Hash256.git ~/hash256-miner
cd ~/hash256-miner
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# 5. Build CUDA library (auto-detects arch)
./build.sh
ls -la cuda/libhash256miner.so

# 6. Configure
cp .env.example .env
nano .env            # set PRIVATE_KEY (and TELEGRAM_* if you want)
chmod 600 .env

# 7. Run
python miner.py
```

</details>

---

## Configuration (`.env`)

After install, edit `.env` (or rerun `bash setup.sh` and use the wizard):

```ini
# ── Wallet (required) ─────────────────────────────────────────────
PRIVATE_KEY=your_private_key_without_0x
RPC_URL=https://eth.llamarpc.com

# ── Telegram alerts (optional, leave empty to disable) ────────────
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

TELEGRAM_NOTIFY_START=1     # miner started
TELEGRAM_NOTIFY_SOLUTION=1  # solution found (before submit)
TELEGRAM_NOTIFY_SUCCESS=1   # tx confirmed (HASH minted)
TELEGRAM_NOTIFY_FAIL=1      # tx failed / submit error
TELEGRAM_NOTIFY_STOP=1      # miner stopped

# ── Tuning (optional, CLI flags override) ─────────────────────────
# BATCH_SIZE=0              # 0 / empty = auto-tune from GPU
# THREADS_PER_BLOCK=256
# GAS_PRICE_GWEI=
# GAS_LIMIT=300000
```

> Your wallet needs ETH for gas. Each `mine()` tx costs ~$1-5 depending on
> network conditions. Use a dedicated mining wallet — not your main one.

### Telegram setup

1. Talk to [@BotFather](https://t.me/BotFather) → `/newbot` → copy the
   token into `TELEGRAM_BOT_TOKEN`.
2. Send any message to your new bot, then visit
   `https://api.telegram.org/bot<TOKEN>/getUpdates` and copy the numeric
   `chat.id` into `TELEGRAM_CHAT_ID`. (Or use [@userinfobot](https://t.me/userinfobot).)
3. Toggle individual events with the `TELEGRAM_NOTIFY_*` flags (`1`/`0`).

You'll receive messages like:

```
🚀 HASH256 miner started
💎 Solution found! (nonce, hash, submitting...)
✅ HASH minted! (tx hash, block, gas used)
🛑 Miner stopped (session stats)
```

---

## Run the Miner

### Foreground (terminal stays open)

```bash
cd ~/hash256-miner
source .venv/bin/activate
python miner.py
```

### Background with `screen` (survives SSH disconnect)

```bash
screen -dmS miner bash -c 'cd ~/hash256-miner && source .venv/bin/activate && python miner.py'
screen -r miner            # attach
# Ctrl+A then D             to detach without stopping
```

### Background with `systemd` (auto-start on reboot)

If you said yes during `setup.sh`, the service is already installed.
Otherwise:

```bash
sudo cp hash256-miner.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hash256-miner
sudo journalctl -fu hash256-miner   # follow logs
```

> Edit the service file beforehand if you want a non-root user or a
> different working directory. `setup.sh` writes a service that uses your
> current user and the venv automatically.

---

## CLI Options

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--private-key`, `-k` | `PRIVATE_KEY` | - | Private key (required) |
| `--rpc`, `-r` | `RPC_URL` | `https://eth.llamarpc.com` | Ethereum RPC endpoint |
| `--batch-size`, `-b` | `BATCH_SIZE` | auto | Nonces per GPU launch (auto-tuned) |
| `--threads`, `-t` | `THREADS_PER_BLOCK` | `256` | CUDA threads per block |
| `--gas-price` | `GAS_PRICE_GWEI` | auto | Gas price in gwei |
| `--gas-limit` | `GAS_LIMIT` | `300000` | Gas limit for `mine()` tx |
| `--cuda-lib` | - | auto | Path to `libhash256miner.so` |
| `--cpu` | - | `false` | Force CPU mode (testing only) |
| `--check-interval` | - | `20` | Re-check on-chain challenge every N batches |
| - | `TELEGRAM_BOT_TOKEN` / `_CHAT_ID` | - | Enables Telegram notifications |
| - | `TELEGRAM_NOTIFY_*` | `1` | Per-event toggles |

---

## GPU Auto-tune

The miner reads compute capability + SM count from `cudaGetDeviceProperties`
and picks a batch size that targets ~150-300 ms per kernel launch — long
enough to amortize launch overhead, short enough to react quickly when the
on-chain epoch changes.

| GPU | Compute | SMs | Auto batch | Approx hashrate |
|-----|---------|-----|------------|-----------------|
| GTX 1080 Ti           | sm_61  | 28    | 16M       | ~150-200 MH/s |
| RTX 2070 Super        | sm_75  | 40    | 32M       | ~300-400 MH/s |
| RTX 2080 Ti           | sm_75  | 68    | 64M       | ~600-800 MH/s |
| RTX 3060              | sm_86  | 28    | 32M       | ~250-350 MH/s |
| RTX 3070 / 3070 Ti    | sm_86  | 46-48 | 64M       | ~600-800 MH/s |
| RTX 3080 / 3080 Ti    | sm_86  | 68-80 | 64M       | ~1.5-2 GH/s   |
| RTX 3090              | sm_86  | 82    | 64M       | ~3.0-3.5 GH/s |
| RTX 3090 Ti           | sm_86  | 84    | 128M      | ~3.2-3.7 GH/s |
| RTX 4060 / 4060 Ti    | sm_89  | 24-34 | 32-64M    | ~400-700 MH/s |
| RTX 4070 / Super      | sm_89  | 46-56 | 64M       | ~1.2-1.6 GH/s |
| RTX 4070 Ti / Super   | sm_89  | 60-66 | 64-128M   | ~1.8-2.5 GH/s |
| RTX 4080 / Super      | sm_89  | 76-80 | 128M      | ~3.0-3.6 GH/s |
| RTX 4090              | sm_89  | 128   | 128M      | ~4.0-5.0 GH/s |
| RTX 5070 / Ti         | sm_120 | 48-70 | 64-128M   | ~1.5-2.5 GH/s |
| RTX 5080              | sm_120 | 84    | 128M      | ~3.5-4.5 GH/s |
| RTX 5090              | sm_120 | 170   | 256M      | ~6.0-8.0 GH/s |
| A100                  | sm_80  | 108   | 128M      | ~3.5 GH/s     |
| H100                  | sm_90  | 132   | 256M      | ~6-8 GH/s     |

> Hashrates are model estimates; real numbers depend on driver, thermals,
> and SKU variant (Ti / Super / Mobile / Founder vs AIB). Override with
> `--batch-size` if you see GPU utilization < 99% in `nvidia-smi`.

---

## Mining Economics

- **Reward:** 100 HASH per successful mint at Era 0
- **Gas cost:** ~$1-5 per `mine()` tx (depends on Ethereum gas price)
- **Halving:** every 100,000 mints the reward halves
- **Competition:** even if you find a valid nonce, another miner whose tx
  lands first in the block will invalidate yours (you'll see
  `execution reverted`). This is normal.

---

## Troubleshooting

### `CUDA library not found`
The shared library was not built or is in the wrong place.
```bash
./build.sh                          # auto-detect arch
# or
cd cuda && make ARCH=sm_86          # explicit arch
ls -la cuda/libhash256miner.so
```

### `Cannot connect to RPC`
Try a different endpoint:
```bash
python miner.py --rpc https://rpc.ankr.com/eth
```
Free public RPCs throttle aggressively. For serious mining use a paid
endpoint (Alchemy, Infura, QuickNode).

### `Genesis phase not complete`
Mining isn't active on-chain yet. Check progress at https://hash256.org.

### `execution reverted` on `mine()` submission
Normal in competitive mining — another miner's tx landed first this block,
or wallet ran out of ETH for gas. Top up and continue.

### Low GPU utilization (`nvidia-smi` < 90%)
- Confirm the library was built for *your* GPU's arch (`./build.sh` does
  this automatically).
- Increase batch size: `python miner.py --batch-size 134217728` (128M).

### Telegram not sending
- Validate token: `curl https://api.telegram.org/bot<TOKEN>/getMe` → must
  return `"ok": true`.
- Validate chat id: send `/start` to your bot, then check
  `https://api.telegram.org/bot<TOKEN>/getUpdates` for `chat.id`.
- Set `TELEGRAM_NOTIFY_*=1` for the events you want.

### After installing the NVIDIA driver, `nvidia-smi` says nothing
A reboot is required. Run `sudo reboot`, then re-run `bash setup.sh`.

---

## Security

- **Never** share your private key. **Never** commit `.env`.
- Use a dedicated mining wallet with only the ETH needed for gas.
- The private key only signs `mine()` calls locally — it is never sent
  anywhere.
- `setup.sh` chmod's `.env` to `600` (owner read-only).
- Telegram messages contain only short hash/nonce previews and tx URLs —
  never your private key.

---

## Project Structure

```
hash256-miner/
├── miner.py              # CLI, mining loop, RPC, Telegram notifier
├── cuda/
│   ├── keccak256.cuh     # Keccak-256 device implementation
│   ├── miner_kernel.cu   # GPU brute-force kernel + host glue
│   └── Makefile          # nvcc build (ARCH ?= sm_86)
├── requirements.txt      # Python deps (web3, eth-account)
├── .env.example          # Config template
├── .env                  # Your config (gitignored, chmod 600)
├── hash256-miner.service # systemd unit
├── setup.sh              # Full one-shot installer (recommended)
├── install.sh            # Lightweight installer (legacy)
├── build.sh              # Just builds the CUDA library
├── .gitignore
└── README.md
```

---

## License

MIT. Use at your own risk — mining costs gas and you're racing other
miners. Past performance is not a guarantee of future hashrate.

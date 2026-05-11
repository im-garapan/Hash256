# HASH256 GPU Miner

GPU-accelerated CLI miner for [HASH token](https://hash256.org) on Ethereum Mainnet using NVIDIA CUDA.

**Contract:** [`0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc`](https://etherscan.io/token/0xac7b5d06fa1e77d08aea40d46cb7c5923a87a0cc)

---

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│  1. Get challenge   →  contract.getChallenge(wallet)        │
│  2. Get difficulty  →  contract.currentDifficulty()         │
│  3. GPU brute-force →  find nonce where                     │
│                         keccak256(challenge || nonce) < diff │
│  4. Submit solution →  contract.mine(nonce)                 │
│  5. Earn 100 HASH  →  repeat!                              │
└─────────────────────────────────────────────────────────────┘
```

---

## Requirements

- **VPS/Server** with NVIDIA GPU (RTX 3060+ recommended)
- **Ubuntu 20.04/22.04/24.04** (tested)
- **NVIDIA Driver** + **CUDA Toolkit** 11.0+
- **Python 3.9+**
- **ETH in wallet** for gas fees (~$1-5 per mint)

---

## Step-by-Step Setup (Fresh VPS)

### Step 1: Update System & Install Dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y build-essential git python3 python3-pip screen
```

### Step 2: Install NVIDIA Drivers

```bash
sudo apt install -y ubuntu-drivers-common
sudo ubuntu-drivers autoinstall
sudo reboot
```

After reboot, verify:
```bash
nvidia-smi
```
You should see your GPU (e.g. RTX 3090).

### Step 3: Install CUDA Toolkit

```bash
sudo apt install -y nvidia-cuda-toolkit
```

Verify:
```bash
nvcc --version
```

### Step 4: Clone the Miner

```bash
git clone --depth 1 -b feat/hash256-gpu-miner https://github.com/mrfunntastiic/artifacts.git /tmp/h256
cp -r /tmp/h256/hash256-miner ~/hash256-miner
rm -rf /tmp/h256
cd ~/hash256-miner
```

### Step 5: Build CUDA Kernel

Choose your GPU architecture:

| GPU | Architecture |
|-----|-------------|
| GTX 1060/1070/1080 | `sm_61` |
| RTX 2060/2070/2080 | `sm_75` |
| RTX 3060/3070/3080/3090 | `sm_86` |
| RTX 4060/4070/4080/4090 | `sm_89` |

Build:
```bash
cd ~/hash256-miner/cuda
make ARCH=sm_86
cd ..
```

Verify the library was built:
```bash
ls -la cuda/libhash256miner.so
```

### Step 6: Install Python Dependencies

```bash
pip3 install web3 eth-account
```

### Step 7: Configure

```bash
cp .env.example .env
nano .env
```

Fill in:
```
PRIVATE_KEY=your_private_key_here_without_0x
RPC_URL=https://eth.llamarpc.com
```

> ⚠️ **IMPORTANT:** Your wallet needs ETH for gas fees. Each `mine()` transaction costs ~$1-5 depending on gas prices.

Save: `Ctrl+O` → `Enter` → `Ctrl+X`

### Step 8: Test Run

```bash
cd ~/hash256-miner
python3 miner.py --batch-size 33554432
```

You should see:
```
  [GPU] GPU: NVIDIA GeForce RTX 3090 | Compute: 8.6 | SMs: 82 | ...
  [RPC] Connected | Chain: 1 | Block: ...
  [WALLET] 0xYourAddress...
  Genesis: Complete
  Reward: 100.0000 HASH/mint
  [START] Mining started!
  [HASH] Batch #0 | 3500.0 MH/s ...
```

### Step 9: Run in Background (Recommended)

So mining continues even when you disconnect SSH:

```bash
screen -dmS miner bash -c 'cd ~/hash256-miner && python3 miner.py --batch-size 33554432'
```

Check mining status:
```bash
screen -r miner
```

Detach without stopping: `Ctrl+A` then `D`

### Step 10 (Optional): Auto-Start on Reboot

```bash
sudo cp ~/hash256-miner/hash256-miner.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now hash256-miner
```

Check logs:
```bash
sudo journalctl -fu hash256-miner
```

---

## Quick One-Liner (if drivers already installed)

```bash
git clone --depth 1 -b feat/hash256-gpu-miner https://github.com/mrfunntastiic/artifacts.git /tmp/h256 && \
cp -r /tmp/h256/hash256-miner ~/hash256-miner && rm -rf /tmp/h256 && \
cd ~/hash256-miner/cuda && make ARCH=sm_86 && cd .. && \
pip3 install web3 eth-account && \
cp .env.example .env && nano .env
```

Then run:
```bash
cd ~/hash256-miner && screen -dmS miner python3 miner.py --batch-size 33554432
```

---

## CLI Options

| Flag | Env Variable | Default | Description |
|------|-------------|---------|-------------|
| `--private-key`, `-k` | `PRIVATE_KEY` | - | Your private key (required) |
| `--rpc`, `-r` | `RPC_URL` | `https://eth.llamarpc.com` | Ethereum RPC endpoint |
| `--batch-size`, `-b` | - | `33554432` (32M) | Nonces per GPU batch |
| `--threads`, `-t` | - | `256` | CUDA threads per block |
| `--gas-price` | - | auto | Gas price in gwei |
| `--gas-limit` | - | `300000` | Gas limit for mine() tx |
| `--cuda-lib` | - | auto-detect | Path to .so library |
| `--cpu` | - | `false` | Use CPU fallback (slow) |

---

## Performance

| GPU | Hashrate | Batch Size |
|-----|----------|-----------|
| GTX 1080 | ~200-400 MH/s | `16777216` |
| RTX 3070 | ~500-800 MH/s | `33554432` |
| RTX 3090 | ~3000-3500 MH/s | `33554432` |
| RTX 4090 | ~4000-5000 MH/s | `33554432` |

---

## Mining Economics

- **Reward:** 100 HASH per successful mint (Era 0)
- **Gas Cost:** ~$1-5 per mint transaction
- **Halving:** Every 100,000 mints the reward halves

---

## Troubleshooting

### "CUDA library not found"
```bash
cd ~/hash256-miner/cuda && make ARCH=sm_86
```

### "Cannot connect to RPC"
Try a different RPC:
```bash
python3 miner.py --rpc https://rpc.ankr.com/eth --batch-size 33554432
```

### "Genesis phase not complete"
Mining hasn't started yet. Wait for genesis to finish at https://hash256.org

### "execution reverted" on submit
- Someone else mined the solution first (epoch changed)
- Insufficient ETH for gas
- This is normal in competitive mining

### Low hashrate
- Make sure you built with correct architecture: `make ARCH=sm_86`
- Try increasing batch size: `--batch-size 67108864` (64M)
- Check GPU utilization: `nvidia-smi`

---

## Security

- ⚠️ **Never share your private key**
- ⚠️ **Never commit `.env` file**
- Use a dedicated mining wallet with minimal ETH
- The private key is only used locally to sign `mine()` transactions

---

## Project Structure

```
hash256-miner/
├── miner.py              # Main CLI & mining loop
├── cuda/
│   ├── keccak256.cuh     # Keccak-256 CUDA implementation
│   ├── miner_kernel.cu   # GPU mining kernel
│   ├── Makefile          # Build script
│   └── libhash256miner.so  # (compiled output)
├── .env.example          # Config template
├── .env                  # Your config (gitignored)
├── requirements.txt      # Python deps
├── hash256-miner.service # systemd service file
├── build.sh             # Build helper
├── install.sh           # Auto-installer
├── .gitignore
└── README.md
```

---

## License

MIT - Use at your own risk. Mining involves gas costs and competition.

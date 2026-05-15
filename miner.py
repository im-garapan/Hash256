#!/usr/bin/env python3
"""
HASH256 GPU Miner CLI
GPU-accelerated miner for HASH token (0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc)

Correct contract flow (from verified ABI):
  1. challenge = getChallenge(minerAddress)  [on-chain]
  2. difficulty = currentDifficulty()
  3. Find nonce where keccak256(challenge || nonce) < difficulty
  4. Submit via mine(uint256 nonce)
"""

from __future__ import annotations

import argparse
import ctypes
import json
import os
import re
import secrets
import signal
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from web3 import Web3
    from eth_account import Account
except ImportError:
    print("ERROR: pip install -r requirements.txt", file=sys.stderr)
    sys.exit(1)


# ============================================================================
# .env loader (robust: strips quotes, handles `export FOO=bar`, inline comments)
# ============================================================================

def load_env_file(path: Path) -> None:
    if not path.exists():
        return
    try:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            # Strip matching quotes
            if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
                value = value[1:-1]
            else:
                # Strip inline comment for unquoted values (preserve URLs with #fragment? rare)
                if " #" in value:
                    value = value.split(" #", 1)[0].rstrip()
            if key:
                os.environ.setdefault(key, value)
    except Exception as e:
        print(f"  [WARN] Failed to parse .env: {e}", file=sys.stderr)


load_env_file(Path(__file__).parent / ".env")


def env_bool(name: str, default: bool = False) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "on", "y")


def env_int(name: str, default: int) -> int:
    v = os.getenv(name)
    if v is None or v.strip() == "":
        return default
    try:
        return int(v.strip())
    except ValueError:
        return default


def env_float(name: str) -> float | None:
    v = os.getenv(name)
    if v is None or v.strip() == "":
        return None
    try:
        return float(v.strip())
    except ValueError:
        return None


# ============================================================================
# Contract config
# ============================================================================

HASH_CONTRACT = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc"
CHAIN_ID = 1  # Ethereum Mainnet

CONTRACT_ABI = json.loads("""[
    {"inputs":[{"internalType":"address","name":"miner","type":"address"}],"name":"getChallenge","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"currentDifficulty","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[{"internalType":"uint256","name":"nonce","type":"uint256"}],"name":"mine","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[],"name":"miningState","outputs":[{"internalType":"uint256","name":"era","type":"uint256"},{"internalType":"uint256","name":"reward","type":"uint256"},{"internalType":"uint256","name":"difficulty","type":"uint256"},{"internalType":"uint256","name":"minted","type":"uint256"},{"internalType":"uint256","name":"remaining","type":"uint256"},{"internalType":"uint256","name":"epoch","type":"uint256"},{"internalType":"uint256","name":"epochBlocksLeft_","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"currentReward","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalMints","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalMiningMinted","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"totalSupply","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"epochBlocksLeft","outputs":[{"internalType":"uint256","name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"genesisComplete","outputs":[{"internalType":"bool","name":"","type":"bool"}],"stateMutability":"view","type":"function"}
]""")


# ============================================================================
# Telegram notifier (stdlib only, runs in background thread)
# ============================================================================

class TelegramNotifier:
    """Fire-and-forget Telegram sender. No external deps; uses urllib."""

    def __init__(self, token: str | None, chat_id: str | None):
        self.enabled = bool(token and chat_id)
        self.token = (token or "").strip()
        self.chat_id = (chat_id or "").strip()
        self._levels = {
            "start":    env_bool("TELEGRAM_NOTIFY_START", True),
            "solution": env_bool("TELEGRAM_NOTIFY_SOLUTION", True),
            "success":  env_bool("TELEGRAM_NOTIFY_SUCCESS", True),
            "fail":     env_bool("TELEGRAM_NOTIFY_FAIL", True),
            "stop":     env_bool("TELEGRAM_NOTIFY_STOP", True),
        }
        if self.enabled:
            print("  [TG] Telegram notifications: enabled")
        else:
            print("  [TG] Telegram notifications: disabled (set TELEGRAM_BOT_TOKEN & TELEGRAM_CHAT_ID)")

    def _send(self, text: str) -> None:
        url = f"https://api.telegram.org/bot{self.token}/sendMessage"
        data = urllib.parse.urlencode({
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }).encode()
        try:
            req = urllib.request.Request(url, data=data, method="POST")
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
        except Exception as e:
            print(f"\n  [TG] Send failed: {e}")

    def send(self, level: str, text: str) -> None:
        if not self.enabled or not self._levels.get(level, True):
            return
        threading.Thread(target=self._send, args=(text,), daemon=True).start()


# ============================================================================
# GPU Miner (CUDA)
# ============================================================================

# Auto-tune table for batch_size (nonces per kernel launch).
#
# Goal: a launch should run for ~150-300 ms.
# - Too short  → kernel-launch overhead dominates, MH/s drops.
# - Too long   → slow reaction to new epoch (challenge changes on-chain).
#
# We score primarily by SM count (linear with throughput) and refine using
# the architecture (Ampere sm_8x → ~5.5 MH/s/SM, Ada sm_89 → ~7 MH/s/SM,
# Blackwell sm_12x → ~9 MH/s/SM, Pascal/Turing → ~3 MH/s/SM).
#
# Final batch is rounded to the nearest 2^N for clean grid sizing.

# Estimated keccak256 throughput per SM (MH/s) on this miner. Conservative.
_SM_RATE_MHPS = {
    # (major, minor): MH/s per SM
    (6, 0): 2.5, (6, 1): 2.5, (6, 2): 2.5,           # Pascal (GTX 10xx)
    (7, 0): 3.5, (7, 2): 3.5, (7, 5): 4.0,           # Volta / Turing (GTX 16xx, RTX 20xx)
    (8, 0): 5.0, (8, 6): 5.5, (8, 7): 5.5,           # Ampere  (RTX 30xx, A100)
    (8, 9): 7.0,                                       # Ada Lovelace (RTX 40xx)
    (9, 0): 8.0,                                       # Hopper  (H100)
    (10, 0): 9.0, (10, 1): 9.0, (10, 2): 9.0,         # Blackwell datacenter
    (12, 0): 9.0, (12, 1): 9.0,                       # Blackwell consumer (RTX 50xx)
}


def _round_to_pow2(n: int, lo: int = 1 << 22, hi: int = 1 << 28) -> int:
    """Round to the nearest power of two within [lo, hi]. Defaults: 4M..256M."""
    n = max(lo, min(hi, int(n)))
    # nearest pow2
    p = 1
    while p < n:
        p <<= 1
    lower = p >> 1
    chosen = p if (n - lower) > (p - n) else lower
    return max(lo, min(hi, chosen))


def auto_tune_batch_size(major: int, minor: int, sm_count: int,
                         target_ms: float = 220.0) -> tuple[int, str]:
    """
    Pick a sensible batch_size for this GPU.
    Returns (batch_size, human_label).
    """
    rate = _SM_RATE_MHPS.get((major, minor))
    if rate is None:
        # Fallback: linear interpolation by major version.
        rate = {6: 2.5, 7: 3.8, 8: 5.5, 9: 8.0, 10: 9.0, 12: 9.0}.get(major, 4.0)

    # Total throughput estimate (hashes/sec)
    total_hps = rate * 1e6 * max(sm_count, 1)
    # Target: target_ms milliseconds per launch
    raw = total_hps * (target_ms / 1000.0)
    batch = _round_to_pow2(raw)

    # Human label
    if batch >= 1 << 27:
        label = f"{batch >> 20}M (full power)"
    elif batch >= 1 << 25:
        label = f"{batch >> 20}M (high)"
    elif batch >= 1 << 23:
        label = f"{batch >> 20}M (balanced)"
    else:
        label = f"{batch >> 20}M (light)"
    return batch, label


# Static lookup table — useful for explanation / docs / when GPU info parse fails.
# Keys are common consumer cards; values are the auto-tuned batch size we expect
# the heuristic above to produce for that GPU.
GPU_PROFILES: dict[str, int] = {
    # ── Pascal (sm_61) ─────────────────────────────────────────────
    "GTX 1060":            1 << 23,   #   8M
    "GTX 1070":            1 << 24,   #  16M
    "GTX 1080":            1 << 24,   #  16M
    "GTX 1080 Ti":         1 << 25,   #  32M
    # ── Turing (sm_75) ─────────────────────────────────────────────
    "GTX 1660":            1 << 23,
    "GTX 1660 Super":      1 << 23,
    "GTX 1660 Ti":         1 << 24,
    "RTX 2060":            1 << 24,
    "RTX 2060 Super":      1 << 24,
    "RTX 2070":            1 << 24,
    "RTX 2070 Super":      1 << 25,
    "RTX 2080":            1 << 25,
    "RTX 2080 Super":      1 << 25,
    "RTX 2080 Ti":         1 << 25,
    # ── Ampere (sm_86) ─────────────────────────────────────────────
    "RTX 3050":            1 << 24,   #  16M
    "RTX 3060":            1 << 25,   #  32M
    "RTX 3060 Ti":         1 << 25,
    "RTX 3070":            1 << 25,
    "RTX 3070 Ti":         1 << 26,
    "RTX 3080":            1 << 26,   #  64M
    "RTX 3080 Ti":         1 << 26,
    "RTX 3090":            1 << 27,   # 128M
    "RTX 3090 Ti":         1 << 27,
    # ── Ada Lovelace (sm_89) ───────────────────────────────────────
    "RTX 4060":            1 << 25,   #  32M
    "RTX 4060 Ti":         1 << 26,
    "RTX 4070":            1 << 26,
    "RTX 4070 Super":      1 << 26,
    "RTX 4070 Ti":         1 << 26,
    "RTX 4070 Ti Super":   1 << 27,
    "RTX 4080":            1 << 27,   # 128M
    "RTX 4080 Super":      1 << 27,
    "RTX 4090":            1 << 28,   # 256M
    # ── Blackwell (sm_120 — consumer RTX 50xx) ─────────────────────
    "RTX 5060":            1 << 25,
    "RTX 5060 Ti":         1 << 26,
    "RTX 5070":            1 << 26,
    "RTX 5070 Ti":         1 << 27,
    "RTX 5080":            1 << 27,
    "RTX 5090":            1 << 28,   # 256M
    # ── Datacenter ────────────────────────────────────────────────
    "A100":                1 << 27,
    "H100":                1 << 28,
    "B100":                1 << 28,
    "B200":                1 << 28,
}


_GPU_INFO_RE = re.compile(
    r"GPU:\s*(?P<name>.+?)\s*\|\s*Compute:\s*(?P<major>\d+)\.(?P<minor>\d+)\s*\|"
    r"\s*SMs:\s*(?P<sms>\d+)"
)


def parse_gpu_info(info: str) -> dict | None:
    """Parse the string returned by get_gpu_info()."""
    m = _GPU_INFO_RE.search(info)
    if not m:
        return None
    return {
        "name": m.group("name").strip(),
        "major": int(m.group("major")),
        "minor": int(m.group("minor")),
        "sms": int(m.group("sms")),
    }


class GPUMiner:
    def __init__(self, lib_path: str | None = None):
        if lib_path is None:
            script_dir = Path(__file__).parent
            for c in (
                script_dir / "cuda" / "libhash256miner.so",
                script_dir / "cuda" / "libhash256miner.dylib",
            ):
                if c.exists():
                    lib_path = str(c)
                    break
        if lib_path is None or not Path(lib_path).exists():
            raise FileNotFoundError(
                "CUDA library not found. Build: cd cuda && make ARCH=sm_86"
            )
        self.lib = ctypes.CDLL(lib_path)

        self.lib.mine_batch.argtypes = [
            ctypes.c_char_p, ctypes.c_char_p,
            ctypes.c_uint64, ctypes.c_uint64, ctypes.c_int,
            ctypes.c_char_p, ctypes.c_char_p,
        ]
        self.lib.mine_batch.restype = ctypes.c_int

        self.lib.get_gpu_info.argtypes = [ctypes.c_char_p, ctypes.c_int]
        self.lib.get_gpu_info.restype = ctypes.c_int

        # Optional: set_job lets us upload challenge/target ONCE per epoch
        # instead of every batch. The C side falls back gracefully if we
        # keep calling mine_batch with hex args.
        try:
            self.lib.set_job.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            self.lib.set_job.restype = ctypes.c_int
            self._has_set_job = True
        except AttributeError:
            self._has_set_job = False

        try:
            self.lib.gpu_cleanup.argtypes = []
            self.lib.gpu_cleanup.restype = None
        except AttributeError:
            pass

        info_buf = ctypes.create_string_buffer(512)
        count = self.lib.get_gpu_info(info_buf, 512)
        info_str = info_buf.value.decode(errors="replace")
        print(f"  [GPU] {info_str} ({count} device(s))")

        self.info_str = info_str
        self.gpu_info = parse_gpu_info(info_str)  # may be None on parse failure

    def recommended_batch_size(self) -> tuple[int, str]:
        """Return (batch_size, label). Falls back to a safe default if probe fails."""
        if not self.gpu_info:
            return 1 << 25, "32M (default — GPU probe failed)"
        return auto_tune_batch_size(
            self.gpu_info["major"],
            self.gpu_info["minor"],
            self.gpu_info["sms"],
        )

    def set_job(self, challenge_hex: str, target_hex: str) -> None:
        if not self._has_set_job:
            return
        c = challenge_hex.replace("0x", "").lower()
        t = target_hex.replace("0x", "").lower()
        self.lib.set_job(c.encode(), t.encode())

    def mine(self, challenge_hex: str, target_hex: str, start_nonce: int,
             batch_size: int = 16777216, threads_per_block: int = 256):
        """Find nonce where keccak256(challenge || nonce) < target."""
        c = challenge_hex.replace("0x", "").lower().encode()
        t = target_hex.replace("0x", "").lower().encode()
        nonce_out = ctypes.create_string_buffer(65)
        hash_out = ctypes.create_string_buffer(65)
        found = self.lib.mine_batch(
            c, t,
            ctypes.c_uint64(start_nonce), ctypes.c_uint64(batch_size),
            ctypes.c_int(threads_per_block), nonce_out, hash_out,
        )
        if found:
            return nonce_out.value.decode(), hash_out.value.decode()
        return None, None

    def cleanup(self) -> None:
        try:
            self.lib.gpu_cleanup()
        except Exception:
            pass


# ============================================================================
# CPU Fallback
# ============================================================================

class CPUMiner:
    def __init__(self):
        print("  [CPU] CPU fallback mode (SLOW - for testing only)")
        self._has_set_job = False
        self.gpu_info = None
        self.info_str = "CPU"

    def recommended_batch_size(self) -> tuple[int, str]:
        return 50_000, "50k (CPU)"

    def set_job(self, *_args, **_kwargs) -> None:
        pass

    def mine(self, challenge_hex, target_hex, start_nonce,
             batch_size=50000, threads_per_block=0):
        challenge_bytes = bytes.fromhex(challenge_hex.replace("0x", ""))
        target_int = int(target_hex.replace("0x", ""), 16)
        keccak = Web3.keccak

        for i in range(batch_size):
            nonce = start_nonce + i
            nonce_bytes = nonce.to_bytes(32, "big")
            h = keccak(challenge_bytes + nonce_bytes)
            if int.from_bytes(h, "big") < target_int:
                return nonce_bytes.hex(), h.hex()
        return None, None

    def cleanup(self) -> None:
        pass


# ============================================================================
# Contract Interaction (with simple retry on transient RPC errors)
# ============================================================================

def _retry(fn, *, attempts: int = 4, base_delay: float = 0.5, label: str = "rpc"):
    last = None
    for n in range(attempts):
        try:
            return fn()
        except Exception as e:
            last = e
            delay = base_delay * (2 ** n)
            print(f"\n  [WARN] {label} failed ({e}); retry in {delay:.1f}s")
            time.sleep(delay)
    raise last  # type: ignore[misc]


class HashContract:
    def __init__(self, rpc_url: str, private_key: str):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 30}))
        if not self.w3.is_connected():
            raise ConnectionError(f"Cannot connect to RPC: {rpc_url}")

        self.contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(HASH_CONTRACT),
            abi=CONTRACT_ABI,
        )
        self.private_key = private_key
        self.account = Account.from_key(private_key)
        self.wallet = self.account.address

        print(f"  [RPC] Connected | Chain: {self.w3.eth.chain_id} | Block: {self.w3.eth.block_number}")
        print(f"  [WALLET] {self.wallet}")

    def get_challenge(self) -> str:
        return _retry(
            lambda: self.contract.functions.getChallenge(self.wallet).call().hex(),
            label="getChallenge",
        )

    def get_difficulty(self) -> int:
        return _retry(
            lambda: self.contract.functions.currentDifficulty().call(),
            label="currentDifficulty",
        )

    def get_job(self) -> tuple[str, int]:
        """Single-RPC-batch friendly: fetch challenge + difficulty back to back."""
        return self.get_challenge(), self.get_difficulty()

    @staticmethod
    def difficulty_to_target_hex(difficulty: int) -> str:
        return difficulty.to_bytes(32, "big").hex()

    def get_mining_state(self) -> dict:
        try:
            r = self.contract.functions.miningState().call()
            return {
                "era": r[0], "reward": r[1], "difficulty": r[2],
                "minted": r[3], "remaining": r[4], "epoch": r[5],
                "epochBlocksLeft": r[6],
            }
        except Exception:
            diff = self.contract.functions.currentDifficulty().call()
            return {"era": 0, "reward": 0, "difficulty": diff, "minted": 0,
                    "remaining": 0, "epoch": 0, "epochBlocksLeft": 0}

    def submit_solution(self, nonce_int: int, gas_price_gwei: float | None = None,
                        gas_limit: int = 300000) -> tuple[bool, str | None, dict | None]:
        tx = self.contract.functions.mine(nonce_int).build_transaction({
            "from": self.wallet,
            "nonce": self.w3.eth.get_transaction_count(self.wallet),
            "gas": gas_limit,
            "gasPrice": (
                self.w3.to_wei(gas_price_gwei, "gwei")
                if gas_price_gwei is not None
                else self.w3.eth.gas_price
            ),
            "chainId": CHAIN_ID,
        })

        signed = self.w3.eth.account.sign_transaction(tx, self.private_key)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        tx_hex = tx_hash.hex()
        print(f"  [TX] Sent: {tx_hex}")
        print(f"  [TX] https://etherscan.io/tx/{tx_hex}")

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
        ok = receipt["status"] == 1
        if ok:
            print(f"  [TX] CONFIRMED! Block: {receipt['blockNumber']} | Gas: {receipt['gasUsed']}")
        else:
            print(f"  [TX] FAILED!")
        return ok, tx_hex, dict(receipt)

    def display_info(self) -> bool:
        try:
            state = self.get_mining_state()
            genesis = self.contract.functions.genesisComplete().call()
            reward_wei = state["reward"]
            reward_hash = float(Web3.from_wei(reward_wei, "ether")) if reward_wei > 0 else 0

            sep = "=" * 55
            print(f"\n  {sep}")
            print(f"  HASH Token - Mining Info")
            print(f"  {sep}")
            print(f"  Contract:      {HASH_CONTRACT}")
            print(f"  Genesis:       {'Complete' if genesis else 'NOT COMPLETE (mining not active!)'}")
            print(f"  Era:           {state['era']}")
            print(f"  Reward:        {reward_hash:.4f} HASH/mint")
            print(f"  Difficulty:    {state['difficulty']}")
            print(f"  Total Minted:  {state['minted']}")
            print(f"  Remaining:     {state['remaining']}")
            print(f"  Epoch:         {state['epoch']}")
            print(f"  Epoch Blocks Left: {state['epochBlocksLeft']}")
            print(f"  {sep}\n")

            if not genesis:
                print("  [!] WARNING: Genesis phase not complete! Mining is NOT active yet.\n")
                return False
            return True
        except Exception as e:
            print(f"  [WARN] Could not fetch contract info: {e}")
            return True


# ============================================================================
# Helpers
# ============================================================================

def fmt_rate(hashes_per_sec: float) -> str:
    if hashes_per_sec >= 1e9:
        return f"{hashes_per_sec / 1e9:.2f} GH/s"
    if hashes_per_sec >= 1e6:
        return f"{hashes_per_sec / 1e6:.1f} MH/s"
    if hashes_per_sec >= 1e3:
        return f"{hashes_per_sec / 1e3:.1f} kH/s"
    return f"{hashes_per_sec:.0f} H/s"


def fmt_duration(seconds: float) -> str:
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


def short_addr(addr: str, head: int = 6, tail: int = 4) -> str:
    return addr[: 2 + head] + "…" + addr[-tail:] if len(addr) > head + tail + 4 else addr


# ============================================================================
# Mining Loop
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="HASH256 GPU Miner - https://hash256.org",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--private-key", "-k",
                        default=os.getenv("PRIVATE_KEY"),
                        help="Private key (or set PRIVATE_KEY in .env)")
    parser.add_argument("--rpc", "-r",
                        default=os.getenv("RPC_URL", "https://eth.llamarpc.com"),
                        help="Ethereum RPC URL")
    parser.add_argument("--batch-size", "-b", type=int,
                        default=env_int("BATCH_SIZE", 0) or None,
                        help="Nonces per GPU batch (default: auto-tune from GPU)")
    parser.add_argument("--threads", "-t", type=int,
                        default=env_int("THREADS_PER_BLOCK", 256),
                        help="CUDA threads per block")
    parser.add_argument("--gas-price", type=float,
                        default=env_float("GAS_PRICE_GWEI"),
                        help="Gas price in gwei (default: auto)")
    parser.add_argument("--gas-limit", type=int,
                        default=env_int("GAS_LIMIT", 300000),
                        help="Gas limit for mine() tx")
    parser.add_argument("--cuda-lib", default=None, help="Path to CUDA library")
    parser.add_argument("--cpu", action="store_true", help="Use CPU miner (testing only)")
    parser.add_argument("--check-interval", type=int, default=20,
                        help="Re-check on-chain challenge every N batches")
    args = parser.parse_args()

    if not args.private_key:
        parser.error("--private-key required (or set PRIVATE_KEY in .env)")

    pk = args.private_key.strip()
    if not pk.startswith("0x"):
        pk = "0x" + pk

    print("""
    ╔══════════════════════════════════════════════════╗
    ║        HASH256 GPU MINER v3.1.0 (FULL POWER)    ║
    ║        Contract: 0xAC7b...A0cc                  ║
    ║        https://hash256.org                      ║
    ╚══════════════════════════════════════════════════╝
    """)

    tg = TelegramNotifier(os.getenv("TELEGRAM_BOT_TOKEN"), os.getenv("TELEGRAM_CHAT_ID"))

    # Init miner backend
    print("  [INIT] Loading miner...")
    if args.cpu:
        miner: GPUMiner | CPUMiner = CPUMiner()
    else:
        try:
            miner = GPUMiner(lib_path=args.cuda_lib)
        except FileNotFoundError as e:
            print(f"  [!] {e}\n  [!] Falling back to CPU...\n")
            miner = CPUMiner()

    # Connect to contract
    print("  [INIT] Connecting to Ethereum...")
    contract = HashContract(args.rpc, pk)
    if not contract.display_info():
        print("  [!] Exiting - mining not active yet.")
        sys.exit(0)

    # Signal handlers (set early so Ctrl+C works during the loop)
    running = True

    def stop(_sig, _frame):
        nonlocal running
        if running:
            print("\n\n  [!] Stopping miner...")
        running = False

    signal.signal(signal.SIGINT, stop)
    try:
        signal.signal(signal.SIGTERM, stop)
    except (ValueError, AttributeError):
        pass  # Windows / non-main-thread

    # Resolve batch size: CLI/env override > auto-tune from GPU profile.
    if args.batch_size is None or args.batch_size <= 0:
        auto_batch, label = miner.recommended_batch_size()
        args.batch_size = auto_batch
        print(f"  [CONFIG] Batch size: {args.batch_size:,}  (auto: {label})")
    else:
        print(f"  [CONFIG] Batch size: {args.batch_size:,}  (manual override)")
    print(f"  [CONFIG] Mode: {'CPU' if args.cpu else 'CUDA GPU'}")
    print(f"  [START] Mining started!\n")

    tg.send("start",
            "🚀 <b>HASH256 miner started</b>\n"
            f"Wallet: <code>{short_addr(contract.wallet)}</code>\n"
            f"Mode: {'CPU' if args.cpu else 'CUDA GPU'}\n"
            f"Batch: {args.batch_size:,}")

    total_hashes = 0
    solutions = 0
    confirmed = 0
    t_session = time.time()
    current_challenge: str | None = None

    try:
        while running:
            try:
                challenge_hex, difficulty = contract.get_job()
                target_hex = contract.difficulty_to_target_hex(difficulty)

                if challenge_hex != current_challenge:
                    current_challenge = challenge_hex
                    miner.set_job(challenge_hex, target_hex)

                print(f"\n  [MINING] Challenge: 0x{challenge_hex[:16]}...")
                print(f"  [MINING] Difficulty: {difficulty}")

                batch_num = 0
                found = False
                # 64-bit random offset (full nonce space minus batch headroom)
                nonce_offset = secrets.randbits(63) & ~((1 << 32) - 1)

                while running and not found:
                    t1 = time.time()
                    start_nonce = nonce_offset + (batch_num * args.batch_size)

                    nonce_hex, hash_hex = miner.mine(
                        challenge_hex, target_hex, start_nonce,
                        batch_size=args.batch_size,
                        threads_per_block=args.threads,
                    )

                    elapsed = max(time.time() - t1, 1e-9)
                    total_hashes += args.batch_size
                    inst_hr = args.batch_size / elapsed
                    avg_hr = total_hashes / max(time.time() - t_session, 1e-9)

                    sys.stdout.write(
                        f"\r  [HASH] Batch #{batch_num} | "
                        f"{fmt_rate(inst_hr)} (avg {fmt_rate(avg_hr)}) | "
                        f"Total: {total_hashes:,} | Sol: {solutions} | OK: {confirmed}"
                    )
                    sys.stdout.flush()

                    if nonce_hex:
                        found = True
                        solutions += 1
                        nonce_int = int(nonce_hex, 16)

                        sep = "=" * 55
                        print(f"\n\n  {sep}")
                        print(f"  SOLUTION FOUND!")
                        print(f"  Nonce: {nonce_int}")
                        print(f"  Hash:  0x{hash_hex}")
                        print(f"  {sep}\n")

                        tg.send("solution",
                                "💎 <b>Solution found!</b>\n"
                                f"Wallet: <code>{short_addr(contract.wallet)}</code>\n"
                                f"Nonce: <code>{nonce_int}</code>\n"
                                f"Hash: <code>0x{hash_hex[:32]}…</code>\n"
                                f"Submitting transaction…")

                        try:
                            ok, tx_hex, receipt = contract.submit_solution(
                                nonce_int,
                                gas_price_gwei=args.gas_price,
                                gas_limit=args.gas_limit,
                            )
                            if ok:
                                confirmed += 1
                                gas_used = receipt["gasUsed"] if receipt else 0
                                block_n = receipt["blockNumber"] if receipt else 0
                                print("  [OK] Minted HASH tokens!\n")
                                tg.send("success",
                                        "✅ <b>HASH minted!</b>\n"
                                        f"Wallet: <code>{short_addr(contract.wallet)}</code>\n"
                                        f"Block: <code>{block_n}</code>\n"
                                        f"Gas used: <code>{gas_used:,}</code>\n"
                                        f"Tx: https://etherscan.io/tx/{tx_hex}\n"
                                        f"Total mints (session): {confirmed}")
                            else:
                                print("  [!] TX failed (someone mined first?)\n")
                                tg.send("fail",
                                        "❌ <b>TX failed</b>\n"
                                        f"Wallet: <code>{short_addr(contract.wallet)}</code>\n"
                                        f"Tx: https://etherscan.io/tx/{tx_hex}")
                        except Exception as e:
                            print(f"  [ERROR] Submit failed: {e}\n")
                            tg.send("fail",
                                    "⚠️ <b>Submit error</b>\n"
                                    f"Wallet: <code>{short_addr(contract.wallet)}</code>\n"
                                    f"Error: <code>{str(e)[:300]}</code>")

                    batch_num += 1

                    if args.check_interval > 0 and batch_num % args.check_interval == 0 and not found:
                        try:
                            new_challenge = contract.get_challenge()
                        except Exception:
                            new_challenge = challenge_hex  # treat transient error as no-change
                        if new_challenge != challenge_hex:
                            print(f"\n  [!] Challenge changed (new epoch), restarting...")
                            break

                if running and not found:
                    time.sleep(1)

            except KeyboardInterrupt:
                break
            except Exception as e:
                print(f"\n  [ERROR] {e} - retry in 5s")
                time.sleep(5)
    finally:
        miner.cleanup()

    total_time = max(time.time() - t_session, 1e-9)
    sep = "=" * 55
    print(f"\n\n  {sep}")
    print(f"  Session: {fmt_duration(total_time)} | Hashes: {total_hashes:,}")
    print(f"  Avg: {fmt_rate(total_hashes / total_time)} | Solutions: {solutions} | Confirmed: {confirmed}")
    print(f"  {sep}\n")

    tg.send("stop",
            "🛑 <b>Miner stopped</b>\n"
            f"Wallet: <code>{short_addr(contract.wallet)}</code>\n"
            f"Session: {fmt_duration(total_time)}\n"
            f"Avg rate: {fmt_rate(total_hashes / total_time)}\n"
            f"Solutions: {solutions} | Confirmed: {confirmed}")
    # Give the daemon thread a brief moment to flush the last message.
    time.sleep(0.5)


if __name__ == "__main__":
    main()

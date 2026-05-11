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

import os
import sys
import time
import ctypes
import argparse
import signal
import json
import random
from pathlib import Path

try:
    from web3 import Web3
    from eth_account import Account
except ImportError:
    print("ERROR: pip install web3 eth-account")
    sys.exit(1)

# Load .env if present
env_file = Path(__file__).parent / ".env"
if env_file.exists():
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())

# Contract config
HASH_CONTRACT = "0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc"
CHAIN_ID = 1  # Ethereum Mainnet

# Verified ABI from anyabi.xyz / Etherscan
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
# GPU Miner (CUDA)
# ============================================================================

class GPUMiner:
    def __init__(self, lib_path=None):
        if lib_path is None:
            script_dir = Path(__file__).parent
            candidates = [
                script_dir / "cuda" / "libhash256miner.so",
                script_dir / "cuda" / "libhash256miner.dylib",
            ]
            for c in candidates:
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
        info_buf = ctypes.create_string_buffer(512)
        count = self.lib.get_gpu_info(info_buf, 512)
        print(f"  [GPU] {info_buf.value.decode()} ({count} device(s))")

    def mine(self, challenge_hex, target_hex, start_nonce, batch_size=16777216, threads_per_block=256):
        """
        Find nonce where keccak256(challenge || nonce) < target.
        challenge_hex: 64-char hex (32 bytes)
        target_hex: 64-char hex (32 bytes) - the difficulty (hash must be < this)
        """
        challenge_hex = challenge_hex.replace("0x", "").lower()
        target_hex = target_hex.replace("0x", "").lower()
        nonce_out = ctypes.create_string_buffer(65)
        hash_out = ctypes.create_string_buffer(65)
        found = self.lib.mine_batch(
            challenge_hex.encode(), target_hex.encode(),
            ctypes.c_uint64(start_nonce), ctypes.c_uint64(batch_size),
            ctypes.c_int(threads_per_block), nonce_out, hash_out,
        )
        if found:
            return nonce_out.value.decode(), hash_out.value.decode()
        return None, None


# ============================================================================
# CPU Fallback
# ============================================================================

class CPUMiner:
    def __init__(self):
        print("  [CPU] CPU fallback mode (SLOW - for testing only)")

    def mine(self, challenge_hex, target_hex, start_nonce, batch_size=50000, threads_per_block=0):
        """CPU brute-force: keccak256(challenge || nonce) < target"""
        challenge_bytes = bytes.fromhex(challenge_hex.replace("0x", ""))
        target_int = int(target_hex.replace("0x", ""), 16)

        for i in range(batch_size):
            nonce = start_nonce + i
            # nonce as uint256 big-endian (32 bytes)
            nonce_bytes = nonce.to_bytes(32, byteorder='big')
            input_data = challenge_bytes + nonce_bytes
            hash_result = Web3.keccak(input_data)
            hash_int = int.from_bytes(hash_result, 'big')

            if hash_int < target_int:
                nonce_hex = nonce_bytes.hex()
                hash_hex = hash_result.hex()
                return nonce_hex, hash_hex

        return None, None


# ============================================================================
# Contract Interaction
# ============================================================================

class HashContract:
    def __init__(self, rpc_url, private_key):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
        if not self.w3.is_connected():
            raise ConnectionError(f"Cannot connect to RPC: {rpc_url}")

        self.contract = self.w3.eth.contract(
            address=Web3.to_checksum_address(HASH_CONTRACT),
            abi=CONTRACT_ABI
        )
        self.private_key = private_key
        self.account = Account.from_key(private_key)
        self.wallet = self.account.address

        print(f"  [RPC] Connected | Chain: {self.w3.eth.chain_id} | Block: {self.w3.eth.block_number}")
        print(f"  [WALLET] {self.wallet}")

    def get_challenge(self):
        """Get current challenge from contract for this miner's address."""
        challenge = self.contract.functions.getChallenge(self.wallet).call()
        return challenge.hex()

    def get_difficulty(self):
        """Get current difficulty. Hash must be < this value to be valid."""
        return self.contract.functions.currentDifficulty().call()

    def difficulty_to_target_hex(self, difficulty):
        """Convert difficulty uint256 to 32-byte hex string for GPU comparison."""
        return difficulty.to_bytes(32, byteorder='big').hex()

    def get_mining_state(self):
        """Get full mining state from contract."""
        try:
            r = self.contract.functions.miningState().call()
            return {
                "era": r[0],
                "reward": r[1],
                "difficulty": r[2],
                "minted": r[3],
                "remaining": r[4],
                "epoch": r[5],
                "epochBlocksLeft": r[6],
            }
        except Exception:
            # Fallback to individual calls
            diff = self.contract.functions.currentDifficulty().call()
            return {"era": 0, "reward": 0, "difficulty": diff, "minted": 0, "remaining": 0, "epoch": 0, "epochBlocksLeft": 0}

    def submit_solution(self, nonce_int, gas_price_gwei=None, gas_limit=300000):
        """Submit mine(uint256 nonce) transaction."""
        tx = self.contract.functions.mine(nonce_int).build_transaction({
            'from': self.wallet,
            'nonce': self.w3.eth.get_transaction_count(self.wallet),
            'gas': gas_limit,
            'gasPrice': self.w3.to_wei(gas_price_gwei, 'gwei') if gas_price_gwei else self.w3.eth.gas_price,
            'chainId': CHAIN_ID,
        })

        signed = self.w3.eth.account.sign_transaction(tx, self.private_key)
        tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        print(f"  [TX] Sent: {tx_hash.hex()}")
        print(f"  [TX] https://etherscan.io/tx/{tx_hash.hex()}")

        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=180)
        if receipt['status'] == 1:
            print(f"  [TX] CONFIRMED! Block: {receipt['blockNumber']} | Gas: {receipt['gasUsed']}")
            return True
        else:
            print(f"  [TX] FAILED!")
            return False

    def display_info(self):
        """Display contract stats."""
        try:
            state = self.get_mining_state()
            genesis = self.contract.functions.genesisComplete().call()
            reward_wei = state["reward"]
            reward_hash = float(Web3.from_wei(reward_wei, 'ether')) if reward_wei > 0 else 0

            print(f"\n  {'='*55}")
            print(f"  HASH Token - Mining Info")
            print(f"  {'='*55}")
            print(f"  Contract:      {HASH_CONTRACT}")
            print(f"  Genesis:       {'Complete' if genesis else 'NOT COMPLETE (mining not active!)'}")
            print(f"  Era:           {state['era']}")
            print(f"  Reward:        {reward_hash:.4f} HASH/mint")
            print(f"  Difficulty:    {state['difficulty']}")
            print(f"  Total Minted:  {state['minted']}")
            print(f"  Remaining:     {state['remaining']}")
            print(f"  Epoch:         {state['epoch']}")
            print(f"  Epoch Blocks Left: {state['epochBlocksLeft']}")
            print(f"  {'='*55}\n")

            if not genesis:
                print("  [!] WARNING: Genesis phase not complete!")
                print("  [!] Mining is NOT active yet. Wait for genesis to finish.")
                print("  [!] Check: https://hash256.org\n")
                return False
            return True
        except Exception as e:
            print(f"  [WARN] Could not fetch contract info: {e}")
            return True  # Continue anyway


# ============================================================================
# Mining Loop
# ============================================================================

def main():
    parser = argparse.ArgumentParser(description="HASH256 GPU Miner - https://hash256.org")
    parser.add_argument("--private-key", "-k",
                        default=os.getenv("PRIVATE_KEY"),
                        help="Private key (or set PRIVATE_KEY env)")
    parser.add_argument("--rpc", "-r",
                        default=os.getenv("RPC_URL", "https://eth.llamarpc.com"),
                        help="Ethereum RPC URL")
    parser.add_argument("--batch-size", "-b", type=int, default=33554432,
                        help="Nonces per GPU batch (default: 32M for RTX 3090)")
    parser.add_argument("--threads", "-t", type=int, default=512,
                        help="CUDA threads per block (default: 512 for max occupancy)")
    parser.add_argument("--gas-price", type=float, default=None,
                        help="Gas price in gwei (default: auto)")
    parser.add_argument("--gas-limit", type=int, default=300000,
                        help="Gas limit for mine() tx")
    parser.add_argument("--cuda-lib", default=None,
                        help="Path to CUDA library")
    parser.add_argument("--cpu", action="store_true",
                        help="Use CPU miner (testing only)")
    args = parser.parse_args()

    if not args.private_key:
        parser.error("--private-key required (or set PRIVATE_KEY in .env)")

    # Normalize private key
    pk = args.private_key.strip()
    if not pk.startswith("0x"):
        pk = "0x" + pk

    print("""
    ╔══════════════════════════════════════════════════╗
    ║        HASH256 GPU MINER v2.1.0                 ║
    ║        Contract: 0xAC7b...A0cc                  ║
    ║        https://hash256.org                      ║
    ╚══════════════════════════════════════════════════╝
    """)

    # Init GPU/CPU miner
    print("  [INIT] Loading miner...")
    if args.cpu:
        miner = CPUMiner()
    else:
        try:
            miner = GPUMiner(lib_path=args.cuda_lib)
        except FileNotFoundError as e:
            print(f"  [!] {e}")
            print("  [!] Falling back to CPU...\n")
            miner = CPUMiner()

    # Connect to contract
    print("  [INIT] Connecting to Ethereum...")
    contract = HashContract(args.rpc, pk)
    mining_active = contract.display_info()

    if not mining_active:
        print("  [!] Exiting - mining not active yet.")
        sys.exit(0)

    # Mining state
    running = True
    total_hashes = 0
    solutions = 0
    t0 = time.time()

    def stop(sig, frame):
        nonlocal running
        print("\n\n  [!] Stopping miner...")
        running = False
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    print(f"  [CONFIG] Batch size: {args.batch_size:,}")
    print(f"  [CONFIG] Mode: {'CPU' if args.cpu else 'CUDA GPU'}")
    print(f"  [START] Mining started!\n")

    while running:
        try:
            # 1. Get challenge from contract (per-miner, per-epoch)
            challenge_hex = contract.get_challenge()

            # 2. Get difficulty
            difficulty = contract.get_difficulty()
            target_hex = contract.difficulty_to_target_hex(difficulty)

            print(f"\n  [MINING] Challenge: 0x{challenge_hex[:16]}...")
            print(f"  [MINING] Difficulty: {difficulty}")

            # 3. Mine in batches
            batch_num = 0
            found = False
            # Random start nonce to avoid collision with other miners
            nonce_offset = random.randint(0, 2**48)

            while running and not found:
                t1 = time.time()
                start_nonce = nonce_offset + (batch_num * args.batch_size)

                nonce_hex, hash_hex = miner.mine(
                    challenge_hex, target_hex, start_nonce,
                    batch_size=args.batch_size, threads_per_block=args.threads
                )

                elapsed = time.time() - t1
                total_hashes += args.batch_size
                hr = args.batch_size / elapsed if elapsed > 0 else 0
                avg_hr = total_hashes / (time.time() - t0)

                sys.stdout.write(
                    f"\r  [HASH] Batch #{batch_num} | "
                    f"{hr/1e6:.1f} MH/s (avg {avg_hr/1e6:.1f}) | "
                    f"Total: {total_hashes:,} | Solutions: {solutions}"
                )
                sys.stdout.flush()

                if nonce_hex:
                    found = True
                    solutions += 1
                    nonce_int = int(nonce_hex, 16)

                    print(f"\n\n  {'='*55}")
                    print(f"  SOLUTION FOUND!")
                    print(f"  Nonce: {nonce_int}")
                    print(f"  Hash:  0x{hash_hex}")
                    print(f"  {'='*55}\n")

                    # 4. Submit: mine(nonce)
                    try:
                        success = contract.submit_solution(
                            nonce_int,
                            gas_price_gwei=args.gas_price,
                            gas_limit=args.gas_limit
                        )
                        if success:
                            print("  [OK] Minted HASH tokens!\n")
                        else:
                            print("  [!] TX failed (someone mined first?)\n")
                    except Exception as e:
                        print(f"  [ERROR] Submit failed: {e}\n")

                batch_num += 1

                # Check if challenge changed every 20 batches
                if batch_num % 20 == 0 and not found:
                    new_challenge = contract.get_challenge()
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

    # Final stats
    total_time = time.time() - t0
    print(f"\n\n  {'='*55}")
    print(f"  Session: {total_time:.0f}s | Hashes: {total_hashes:,}")
    print(f"  Avg: {total_hashes/total_time/1e6:.1f} MH/s | Solutions: {solutions}")
    print(f"  {'='*55}\n")


if __name__ == "__main__":
    main()

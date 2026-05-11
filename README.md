# HASH Token CPU Miner

A CPU miner for the HASH token that runs on Ethereum mainnet using ethers.js for wallet connection.

## Features

- 🔄 Automatic epoch detection and challenge generation
- ⛏️ CPU-based keccak256 proof-of-work mining
- 💰 Automatic reward calculation based on current era
- 📊 Real-time hash rate and statistics display
- 🔐 Secure wallet connection using ethers.js
- 🛡️ Error handling and graceful shutdown
- 📈 Contract information display

## Requirements

- Node.js 16+ 
- Ethereum wallet with ETH for gas fees
- Private key for the mining wallet

## Installation

```bash
cd hash-miner
npm install
```

## Usage

### Method 1: Environment Variable (Recommended)

```bash
export PRIVATE_KEY="your_private_key_here"
npm start
```

### Method 2: Interactive Prompt

```bash
npm start
# Enter your private key when prompted
```

## Configuration

The miner uses the following default settings:

- **Contract Address**: `0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc`
- **RPC URL**: `https://eth-mainnet.g.alchemy.com/v2/demo` (free demo, replace with your own)
- **Chain ID**: 1 (Ethereum Mainnet)
- **Gas Limit**: 300,000
- **Gas Price**: 20 Gwei

To use your own RPC provider, modify the `RPC_URL` constant in `miner.js`.

## Mining Mechanics

The miner implements the HASH token proof-of-work algorithm:

1. **Challenge Generation**: `keccak256(chainId ‖ contract ‖ miner ‖ epoch)`
2. **Proof Validation**: `keccak256(challenge ‖ nonce) < currentDifficulty`
3. **Reward Calculation**: `BASE_REWARD >> era` where `era = totalMints / 100,000`

### Reward Schedule

- Era 1: 100.00 HASH per mint
- Era 2: 50.00 HASH per mint  
- Era 3: 25.00 HASH per mint
- Era 4: 12.50 HASH per mint
- Era 5+: 6.25 HASH per mint

## Security Notes

⚠️ **Important Security Considerations:**

1. **Private Key Security**: Never commit your private key to version control
2. **Environment Variables**: Use environment variables for sensitive data
3. **Network Security**: Use reputable RPC providers
4. **Gas Costs**: Mining requires ETH for transaction fees

## Example Output

```
🔐 HASH Token CPU Miner
========================

🔨 HASH Miner initialized
📍 Miner Address: 0x1234...
⛽ RPC URL: https://eth-mainnet.g.alchemy.com/v2/demo

📋 Contract Information:
   Total Supply: 1,050,000.0 HASH
   Total Mints: 10500
   Current Difficulty: 57896044618658097711785492504343953926634992332820282019728792003956564819968
   Current Epoch: 42
   Current Reward: 50.00 HASH per mint

🚀 Starting mining process...

📊 Current Status:
   Epoch: 42
   Difficulty: 57896044618658097711785492504343953926634992332820282019728792003956564819968
   Challenge: 0x8f3a2b1c...

⛏️  Mining for epoch 42...
⚡ Hash rate: 1250.50 H/s | Attempts: 12,500
🎉 FOUND VALID NONCE: 8423957
📤 Submitting solution to contract...
📋 Transaction submitted: 0xabc123...
⏳ Waiting for confirmation...
✅ SUCCESS! Transaction confirmed in block 19876543
🔗 Etherscan: https://etherscan.io/tx/0xabc123...
🏆 Mined 50.00 HASH tokens!
📈 Total successful mints: 1
```

## Stopping the Miner

Use `Ctrl+C` to gracefully stop the miner. Statistics will be displayed upon shutdown.

## Troubleshooting

### Common Issues

1. **Insufficient Gas**: Ensure your wallet has enough ETH for transaction fees
2. **RPC Issues**: Try a different RPC endpoint if connection fails
3. **Epoch Changes**: The miner automatically handles epoch rotations
4. **Network Congestion**: High gas prices may affect mining profitability

### Debug Mode

For additional debugging, modify the log levels in the code or add more console.log statements.

## License

MIT License - Use at your own risk. Mining involves financial risks and costs.

## Donations

If you find this miner useful, consider donating to the HASH project at the official contract address.

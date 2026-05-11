const { ethers } = require('ethers');
const crypto = require('crypto');

// HASH Token Contract Configuration
const HASH_CONTRACT_ADDRESS = '0xAC7b5d06fa1e77D08aea40d46cB7C5923A87A0cc';
const RPC_URL = 'https://eth-mainnet.g.alchemy.com/v2/demo'; // Free demo RPC, replace with your own
const CHAIN_ID = 1; // Ethereum Mainnet

// ABI for HASH contract (minimal functions needed)
const HASH_ABI = [
    'function currentDifficulty() view returns (uint256)',
    'function currentEpoch() view returns (uint256)',
    'function mint(bytes32 challenge, uint256 nonce) external',
    'function hashTotalSupply() view returns (uint256)',
    'function totalMints() view returns (uint256)'
];

class HashMiner {
    constructor(privateKey) {
        this.provider = new ethers.JsonRpcProvider(RPC_URL);
        this.wallet = new ethers.Wallet(privateKey, this.provider);
        this.contract = new ethers.Contract(HASH_CONTRACT_ADDRESS, HASH_ABI, this.wallet);
        
        this.minerAddress = this.wallet.address;
        this.isRunning = false;
        this.stats = {
            attempts: 0,
            successCount: 0,
            startTime: null,
            lastSuccessTime: null,
            currentDifficulty: 0,
            currentEpoch: 0
        };
        
        console.log(`🔨 HASH Miner initialized`);
        console.log(`📍 Miner Address: ${this.minerAddress}`);
        console.log(`⛽ RPC URL: ${RPC_URL}`);
    }

    async getChallenge() {
        const epoch = await this.contract.currentEpoch();
        const challenge = ethers.solidityPackedKeccak256(
            ['uint256', 'address', 'address', 'uint256'],
            [CHAIN_ID, HASH_CONTRACT_ADDRESS, this.minerAddress, epoch]
        );
        
        this.stats.currentEpoch = Number(epoch);
        return { challenge, epoch: Number(epoch) };
    }

    async getCurrentDifficulty() {
        const difficulty = await this.contract.currentDifficulty();
        this.stats.currentDifficulty = difficulty.toString();
        return difficulty;
    }

    async checkProof(challenge, nonce, targetDifficulty) {
        const hash = ethers.solidityPackedKeccak256(
            ['bytes32', 'uint256'],
            [challenge, nonce]
        );
        
        return hash < targetDifficulty;
    }

    async mine() {
        console.log('\n🚀 Starting mining process...');
        this.isRunning = true;
        this.stats.startTime = Date.now();

        while (this.isRunning) {
            try {
                // Get current challenge and difficulty
                const { challenge, epoch } = await this.getChallenge();
                const difficulty = await this.getCurrentDifficulty();
                
                console.log(`\n📊 Current Status:`);
                console.log(`   Epoch: ${epoch}`);
                console.log(`   Difficulty: ${difficulty.toString()}`);
                console.log(`   Challenge: ${challenge.slice(0, 20)}...`);
                
                let nonce = BigInt(0);
                let found = false;
                
                console.log(`⛏️  Mining for epoch ${epoch}...`);
                
                // Mining loop
                while (!found && this.isRunning) {
                    // Check if epoch changed
                    const currentEpoch = await this.contract.currentEpoch();
                    if (Number(currentEpoch) !== epoch) {
                        console.log(`🔄 Epoch changed from ${epoch} to ${currentEpoch}, restarting...`);
                        break;
                    }
                    
                    // Try current nonce
                    const isValid = await this.checkProof(challenge, nonce, difficulty);
                    this.stats.attempts++;
                    
                    if (isValid) {
                        found = true;
                        console.log(`🎉 FOUND VALID NONCE: ${nonce.toString()}`);
                        
                        // Submit the solution
                        await this.submitSolution(challenge, nonce);
                        break;
                    }
                    
                    // Increment nonce
                    nonce++;
                    
                    // Progress indicator every 10000 attempts
                    if (this.stats.attempts % 10000 === 0) {
                        const elapsed = (Date.now() - this.stats.startTime) / 1000;
                        const rate = (this.stats.attempts / elapsed).toFixed(2);
                        process.stdout.write(`\r⚡ Hash rate: ${rate} H/s | Attempts: ${this.stats.attempts.toLocaleString()}`);
                    }
                }
                
                // Small delay before next attempt
                await new Promise(resolve => setTimeout(resolve, 100));
                
            } catch (error) {
                console.error('❌ Mining error:', error.message);
                await new Promise(resolve => setTimeout(resolve, 5000)); // Wait 5 seconds on error
            }
        }
    }

    async submitSolution(challenge, nonce) {
        try {
            console.log(`📤 Submitting solution to contract...`);
            
            const tx = await this.contract.mint(challenge, nonce, {
                gasLimit: 300000,
                gasPrice: ethers.parseUnits('20', 'gwei')
            });
            
            console.log(`📋 Transaction submitted: ${tx.hash}`);
            console.log(`⏳ Waiting for confirmation...`);
            
            const receipt = await tx.wait();
            
            if (receipt.status === 1) {
                console.log(`✅ SUCCESS! Transaction confirmed in block ${receipt.blockNumber}`);
                console.log(`🔗 Etherscan: https://etherscan.io/tx/${tx.hash}`);
                
                this.stats.successCount++;
                this.stats.lastSuccessTime = Date.now();
                
                // Calculate reward
                const totalMints = await this.contract.totalMints();
                const era = Math.floor(Number(totalMints) / 100000);
                const reward = 100 / Math.pow(2, era);
                
                console.log(`🏆 Mined ${reward.toFixed(2)} HASH tokens!`);
                console.log(`📈 Total successful mints: ${this.stats.successCount}`);
                
            } else {
                console.log(`❌ Transaction failed`);
            }
            
        } catch (error) {
            console.error(`❌ Submission failed:`, error.message);
        }
    }

    stop() {
        this.isRunning = false;
        console.log('\n🛑 Mining stopped');
        
        const elapsed = (Date.now() - this.stats.startTime) / 1000;
        const rate = (this.stats.attempts / elapsed).toFixed(2);
        
        console.log('\n📊 Final Statistics:');
        console.log(`   Total Attempts: ${this.stats.attempts.toLocaleString()}`);
        console.log(`   Successful Mints: ${this.stats.successCount}`);
        console.log(`   Average Hash Rate: ${rate} H/s`);
        console.log(`   Mining Duration: ${elapsed.toFixed(2)} seconds`);
    }

    async displayContractInfo() {
        try {
            const totalSupply = await this.contract.hashTotalSupply();
            const totalMints = await this.contract.totalMints();
            const difficulty = await this.contract.currentDifficulty();
            const epoch = await this.contract.currentEpoch();
            
            console.log('\n📋 Contract Information:');
            console.log(`   Total Supply: ${ethers.formatUnits(totalSupply, 18)} HASH`);
            console.log(`   Total Mints: ${totalMints.toString()}`);
            console.log(`   Current Difficulty: ${difficulty.toString()}`);
            console.log(`   Current Epoch: ${epoch.toString()}`);
            
            const era = Math.floor(Number(totalMints) / 100000);
            const currentReward = 100 / Math.pow(2, era);
            console.log(`   Current Reward: ${currentReward.toFixed(2)} HASH per mint`);
            
        } catch (error) {
            console.error('❌ Failed to fetch contract info:', error.message);
        }
    }
}

// Main execution
async function main() {
    console.log('🔐 HASH Token CPU Miner');
    console.log('========================\n');
    
    // Get private key from environment variable or prompt
    let privateKey = process.env.PRIVATE_KEY;
    
    if (!privateKey) {
        console.log('⚠️  No PRIVATE_KEY environment variable found.');
        console.log('📝 Please enter your private key (or set PRIVATE_KEY env var):');
        
        // In production, you should use a more secure method
        const readline = require('readline');
        const rl = readline.createInterface({
            input: process.stdin,
            output: process.stdout
        });
        
        privateKey = await new Promise(resolve => {
            rl.question('Private Key: ', answer => {
                rl.close();
                resolve(answer.trim());
            });
        });
    }
    
    if (!privateKey || privateKey.length < 64) {
        console.error('❌ Invalid private key provided');
        process.exit(1);
    }
    
    const miner = new HashMiner(privateKey);
    
    // Display contract info
    await miner.displayContractInfo();
    
    // Handle graceful shutdown
    process.on('SIGINT', () => {
        miner.stop();
        process.exit(0);
    });
    
    process.on('SIGTERM', () => {
        miner.stop();
        process.exit(0);
    });
    
    // Start mining
    await miner.mine();
}

// Error handling
process.on('unhandledRejection', (reason, promise) => {
    console.error('❌ Unhandled Rejection at:', promise, 'reason:', reason);
    process.exit(1);
});

process.on('uncaughtException', (error) => {
    console.error('❌ Uncaught Exception:', error);
    process.exit(1);
});

// Run the miner
if (require.main === module) {
    main().catch(error => {
        console.error('❌ Fatal error:', error);
        process.exit(1);
    });
}

module.exports = { HashMiner };

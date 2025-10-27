#!/bin/bash

# Load environment variables
source .env

echo "🚀 Deploying MockUSDC to Sepolia..."
echo ""

# Run deployment script
forge script script/DeployMockUSDC.s.sol:DeployMockUSDC \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

echo ""
echo "✅ MockUSDC deployment complete!"
echo "📝 You can now transfer USDC to your team members for testing"

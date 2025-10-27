#!/bin/bash

# Load environment variables
source .env

echo "🚀 Deploying DeLong Protocol v1 to Sepolia..."
echo ""

# Run deployment script
forge script script/DeploySepolia.s.sol:DeploySepolia \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

echo ""
echo "✅ Deployment complete!"
echo "📄 Check deployments/sepolia.env for contract addresses"

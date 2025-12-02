#!/bin/bash

set -e  # Exit on error

# Load environment variables
source .env

echo "🚀 Deploying DeLong Protocol v1 to Sepolia..."
echo ""

# Run deployment script
if forge script script/DeploySepolia.s.sol:DeploySepolia \
    --rpc-url $RPC_URL \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv; then
    echo ""
    echo "✅ Deployment complete!"
    echo "📄 Check deployments/sepolia.env for contract addresses"
else
    echo ""
    echo "❌ Deployment failed!"
    echo "Please check the error message above."
    exit 1
fi

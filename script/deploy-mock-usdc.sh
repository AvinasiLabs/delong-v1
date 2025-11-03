#!/bin/bash

# Load environment variables
source .env

echo "🚀 Deploying MockUSDC (50,000 USDC per wallet) to Sepolia..."
echo ""

# Deploy using forge script
forge script script/DeployMockUSDC.s.sol:DeployMockUSDC \
    --rpc-url $RPC_URL \
    --broadcast \
    --legacy \
    -vvvv

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Please update the USDC_ADDRESS in both .env files:"
echo "  1. /Users/lilhammer/workspace/delong/delong-v1/.env"
echo "  2. /Users/lilhammer/workspace/delong/dlex-backend/.env"

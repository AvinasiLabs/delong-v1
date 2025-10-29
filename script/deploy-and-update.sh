#!/bin/bash

# Exit on error
set -e

echo "🚀 DeLong Protocol v1 - Full Deployment & Configuration Update"
echo "=============================================================="
echo ""

# Step 1: Deploy contracts
echo "📦 Step 1: Deploying contracts to Sepolia..."
source .env
forge script script/DeploySepolia.s.sol:DeploySepolia \
    --rpc-url $RPC_URL \
    --broadcast \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

if [ $? -ne 0 ]; then
    echo "❌ Contract deployment failed!"
    exit 1
fi

echo ""
echo "✅ Contracts deployed successfully!"
echo ""

# Step 2: Load deployment addresses
echo "📋 Step 2: Loading deployment addresses..."
if [ ! -f "./deployments/sepolia.env" ]; then
    echo "❌ Deployment file not found: ./deployments/sepolia.env"
    exit 1
fi

source ./deployments/sepolia.env

echo "Loaded addresses:"
echo "  Factory: $FACTORY_ADDRESS"
echo "  RentalManager: $RENTAL_MANAGER_ADDRESS"
echo "  DAOTreasury: $DAO_TREASURY_ADDRESS"
echo "  DAOGovernance: $DAO_GOVERNANCE_ADDRESS"
echo ""

# Get startBlock from latest deployment
START_BLOCK=$(cast block-number --rpc-url $RPC_URL)
echo "Current block number: $START_BLOCK"
echo ""

# Step 3: Update subgraph configuration
echo "🔧 Step 3: Updating subgraph configuration..."
SUBGRAPH_FILE="./subgraph/subgraph.yaml"

if [ ! -f "$SUBGRAPH_FILE" ]; then
    echo "❌ Subgraph file not found: $SUBGRAPH_FILE"
    exit 1
fi

# Backup original file
cp "$SUBGRAPH_FILE" "$SUBGRAPH_FILE.backup"

# Update Factory address and startBlock
sed -i.tmp "s/address: \"0x[a-fA-F0-9]*\" # Factory/address: \"$FACTORY_ADDRESS\"/g" "$SUBGRAPH_FILE"
sed -i.tmp "/name: Factory/,/startBlock:/ s/startBlock: [0-9]*/startBlock: $START_BLOCK/" "$SUBGRAPH_FILE"

# Update RentalManager address and startBlock
sed -i.tmp "/name: RentalManager/,/startBlock:/ s/address: \"0x[a-fA-F0-9]*\"/address: \"$RENTAL_MANAGER_ADDRESS\"/" "$SUBGRAPH_FILE"
sed -i.tmp "/name: RentalManager/,/startBlock:/ s/startBlock: [0-9]*/startBlock: $START_BLOCK/" "$SUBGRAPH_FILE"

# Update DAOTreasury address and startBlock
sed -i.tmp "/name: DAOTreasury/,/startBlock:/ s/address: \"0x[a-fA-F0-9]*\"/address: \"$DAO_TREASURY_ADDRESS\"/" "$SUBGRAPH_FILE"
sed -i.tmp "/name: DAOTreasury/,/startBlock:/ s/startBlock: [0-9]*/startBlock: $START_BLOCK/" "$SUBGRAPH_FILE"

# Update DAOGovernance address and startBlock
sed -i.tmp "/name: DAOGovernance/,/startBlock:/ s/address: \"0x[a-fA-F0-9]*\"/address: \"$DAO_GOVERNANCE_ADDRESS\"/" "$SUBGRAPH_FILE"
sed -i.tmp "/name: DAOGovernance/,/startBlock:/ s/startBlock: [0-9]*/startBlock: $START_BLOCK/" "$SUBGRAPH_FILE"

# Clean up temp files
rm -f "$SUBGRAPH_FILE.tmp"

echo "✅ Subgraph configuration updated!"
echo ""

# Step 4: Update frontend .env.local
echo "🌐 Step 4: Updating frontend environment variables..."
FRONTEND_ENV="../dlex/.env.local"

if [ ! -f "$FRONTEND_ENV" ]; then
    echo "❌ Frontend .env file not found: $FRONTEND_ENV"
    exit 1
fi

# Backup original file
cp "$FRONTEND_ENV" "$FRONTEND_ENV.backup"

# Update Sepolia addresses
sed -i.tmp "s/NEXT_PUBLIC_FACTORY_ADDRESS_SEPOLIA=.*/NEXT_PUBLIC_FACTORY_ADDRESS_SEPOLIA=$FACTORY_ADDRESS/" "$FRONTEND_ENV"
sed -i.tmp "s/NEXT_PUBLIC_RENTAL_MANAGER_ADDRESS_SEPOLIA=.*/NEXT_PUBLIC_RENTAL_MANAGER_ADDRESS_SEPOLIA=$RENTAL_MANAGER_ADDRESS/" "$FRONTEND_ENV"
sed -i.tmp "s/NEXT_PUBLIC_DAO_TREASURY_ADDRESS_SEPOLIA=.*/NEXT_PUBLIC_DAO_TREASURY_ADDRESS_SEPOLIA=$DAO_TREASURY_ADDRESS/" "$FRONTEND_ENV"
sed -i.tmp "s/NEXT_PUBLIC_DAO_GOVERNANCE_ADDRESS_SEPOLIA=.*/NEXT_PUBLIC_DAO_GOVERNANCE_ADDRESS_SEPOLIA=$DAO_GOVERNANCE_ADDRESS/" "$FRONTEND_ENV"
sed -i.tmp "s/NEXT_PUBLIC_USDC_ADDRESS_SEPOLIA=.*/NEXT_PUBLIC_USDC_ADDRESS_SEPOLIA=$USDC_ADDRESS/" "$FRONTEND_ENV"

# Clean up temp files
rm -f "$FRONTEND_ENV.tmp"

echo "✅ Frontend environment variables updated!"
echo ""

# Step 5: Print summary
echo "=============================================================="
echo "✨ Deployment & Configuration Complete!"
echo "=============================================================="
echo ""
echo "📝 Updated Files:"
echo "  1. Contract deployments: ./deployments/sepolia.env"
echo "  2. Subgraph config: ./subgraph/subgraph.yaml"
echo "  3. Frontend env: ../dlex/.env.local"
echo ""
echo "🔄 Next Steps:"
echo ""
echo "1. Deploy subgraph to The Graph Studio:"
echo "   cd subgraph"
echo "   pnpm run codegen"
echo "   pnpm run build"
echo "   pnpm run deploy"
echo ""
echo "2. Restart backend services (if running):"
echo "   cd ../dlex-backend"
echo "   docker-compose down"
echo "   docker-compose build --no-cache aggregator-service"
echo "   docker-compose up -d"
echo ""
echo "3. Frontend will auto-reload with new addresses"
echo ""
echo "📋 Backup files saved:"
echo "  - $SUBGRAPH_FILE.backup"
echo "  - $FRONTEND_ENV.backup"
echo ""
echo "🎉 Done!"

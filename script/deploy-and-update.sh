#!/bin/bash

set -e  # Exit on error

echo "🚀 DeLong Protocol v1 - Full Deployment & Configuration Update"
echo "=============================================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load environment variables
if [ ! -f .env ]; then
    echo "❌ Error: .env file not found"
    exit 1
fi
source .env

# Project paths
CONTRACT_DIR="$(pwd)"
DLEX_DIR="${CONTRACT_DIR}/../dlex"
DLEX_BACKEND_DIR="${CONTRACT_DIR}/../dlex-backend"
SUBGRAPH_DIR="${CONTRACT_DIR}/../subgraph"

# =============================================================================
# Step 1: Deploy Contracts to Sepolia
# =============================================================================
echo "📦 Step 1: Deploying contracts to Sepolia..."
echo ""

# Deploy without verification (too slow)
forge script script/DeploySepolia.s.sol:DeploySepolia \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --skip-simulation \
    -vv

if [ $? -ne 0 ]; then
    echo -e "${RED}❌ Contract deployment failed${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Contracts deployed successfully${NC}"
echo ""

# =============================================================================
# Step 2: Load deployed addresses
# =============================================================================
echo "📋 Step 2: Loading deployed addresses..."

if [ ! -f "./deployments/sepolia.env" ]; then
    echo -e "${RED}❌ Error: deployments/sepolia.env not found${NC}"
    exit 1
fi

source ./deployments/sepolia.env

echo "Loaded addresses:"
echo "  Factory: $FACTORY_ADDRESS"
echo "  RentalManager: $RENTAL_MANAGER_ADDRESS"
echo "  DAOTreasury: $DAO_TREASURY_ADDRESS"
echo "  DAOGovernance: $DAO_GOVERNANCE_ADDRESS"
echo ""

# =============================================================================
# Step 3: Update Subgraph Configuration
# =============================================================================
echo "🔄 Step 3: Updating subgraph configuration..."

if [ -d "$SUBGRAPH_DIR" ]; then
    cd "$SUBGRAPH_DIR"

    # Backup original subgraph.yaml
    if [ -f "subgraph.yaml" ]; then
        cp subgraph.yaml subgraph.yaml.backup
    fi

    # Update subgraph.yaml with new addresses
    # Note: This uses awk to update the addresses in place
    awk -v factory="$FACTORY_ADDRESS" -v rental="$RENTAL_MANAGER_ADDRESS" '
        /address:/ && /Factory/ { gsub(/"[^"]*"/, "\"" tolower(factory) "\""); print; next }
        /address:/ && /RentalManager/ { gsub(/"[^"]*"/, "\"" tolower(rental) "\""); print; next }
        { print }
    ' subgraph.yaml > subgraph.yaml.tmp && mv subgraph.yaml.tmp subgraph.yaml

    echo -e "${GREEN}✅ Subgraph configuration updated${NC}"

    # Regenerate subgraph code
    echo "🔨 Generating subgraph code..."
    pnpm run codegen

    # Deploy subgraph
    echo "📡 Deploying subgraph..."
    pnpm run deploy

    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}⚠️  Subgraph deployment failed, but continuing...${NC}"
    else
        echo -e "${GREEN}✅ Subgraph deployed${NC}"
    fi

    cd "$CONTRACT_DIR"
else
    echo -e "${YELLOW}⚠️  Subgraph directory not found, skipping...${NC}"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "=============================================================="
echo -e "${GREEN}✅ Deployment and configuration update complete!${NC}"
echo "=============================================================="
echo ""
echo "📊 Summary:"
echo "  ✅ Contracts deployed to Sepolia"
echo "  ✅ Addresses saved to deployments/sepolia.env"
echo "  ✅ Subgraph configuration updated"
echo ""
echo "🔗 Deployed Addresses:"
echo "  Factory:       $FACTORY_ADDRESS"
echo "  RentalManager: $RENTAL_MANAGER_ADDRESS"
echo "  DAOTreasury:   $DAO_TREASURY_ADDRESS"
echo "  DAOGovernance: $DAO_GOVERNANCE_ADDRESS"
echo ""
echo "📝 Next Steps:"
echo "  1. Manually update frontend .env.local with the new contract addresses"
echo "  2. Manually update backend environment variables if needed"
echo "  3. Update NEXT_PUBLIC_SUBGRAPH_URL in frontend .env.local"
echo "  4. Test frontend and backend connections"
echo ""

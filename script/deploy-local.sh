#!/bin/bash

# DeLong Protocol v1 - Local Deployment Script
# This script deploys all contracts to a local Anvil node

set -e

echo "======================================"
echo "DeLong Protocol v1 - Local Deployment"
echo "======================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Check if Anvil is running
if ! nc -z localhost 8545 2>/dev/null; then
    echo -e "${RED}Error: Anvil is not running on port 8545${NC}"
    echo "Please start Anvil in another terminal with: anvil"
    exit 1
fi

echo -e "${GREEN}✓ Anvil is running${NC}"
echo ""

# Deploy contracts
echo "Deploying contracts..."
echo ""

forge script script/Deploy.s.sol:Deploy \
    --rpc-url http://localhost:8545 \
    --broadcast \
    -vvv

echo ""
echo -e "${GREEN}======================================"
echo "Deployment Complete!"
echo "======================================${NC}"
echo ""
echo "Contract addresses have been saved to:"
echo "  broadcast/Deploy.s.sol/31337/run-latest.json"
echo ""
echo "Next steps:"
echo "  1. Deploy a dataset:"
echo "     ./script/deploy-dataset.sh"
echo ""
echo "  2. Interact with contracts:"
echo "     ./script/interact.sh"
echo ""

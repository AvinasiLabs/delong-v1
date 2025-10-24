#!/bin/bash

# Deploy a dataset using the Factory contract

set -e

echo "======================================"
echo "Deploy Dataset"
echo "======================================"
echo ""

# Get contract addresses from deployment
BROADCAST_DIR="broadcast/Deploy.s.sol/31337"
if [ ! -f "$BROADCAST_DIR/run-latest.json" ]; then
    echo "Error: Deployment artifacts not found. Please run ./script/deploy-local.sh first"
    exit 1
fi

echo "Note: Update the contract addresses in script/DeployDataset.s.sol"
echo "You can find them in: $BROADCAST_DIR/run-latest.json"
echo ""

# Parse addresses (requires jq)
if command -v jq &> /dev/null; then
    USDC=$(jq -r '.transactions[] | select(.contractName == "MockUSDC") | .contractAddress' "$BROADCAST_DIR/run-latest.json" 2>/dev/null || echo "")
    FACTORY=$(jq -r '.transactions[] | select(.contractName == "Factory") | .contractAddress' "$BROADCAST_DIR/run-latest.json" 2>/dev/null || echo "")

    if [ ! -z "$USDC" ] && [ ! -z "$FACTORY" ]; then
        echo "Found addresses:"
        echo "  USDC:    $USDC"
        echo "  Factory: $FACTORY"
        echo ""
        echo "Update these in script/DeployDataset.s.sol if needed"
        echo ""
    fi
fi

read -p "Press Enter to continue with deployment..."

forge script script/DeployDataset.s.sol:DeployDataset \
    --rpc-url http://localhost:8545 \
    --broadcast \
    -vvv

echo ""
echo "Dataset deployed!"
echo ""

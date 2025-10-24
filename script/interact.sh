#!/bin/bash

# Interactive script for DeLong Protocol operations

echo "======================================"
echo "DeLong Protocol - Interact"
echo "======================================"
echo ""
echo "Select an operation:"
echo "  1) Buy Tokens (IDO)"
echo "  2) Sell Tokens (IDO)"
echo "  3) Rent Dataset Access"
echo "  4) Claim Dividends"
echo "  5) Check Balances"
echo "  6) Exit"
echo ""

read -p "Enter choice [1-6]: " choice

case $choice in
    1)
        echo ""
        echo "=== Buy Tokens ==="
        read -p "IDO Address: " IDO_ADDRESS
        read -p "USDC Address: " USDC_ADDRESS
        read -p "Token Amount (in tokens, e.g., 1000): " TOKEN_AMOUNT_HUMAN
        read -p "Max Cost (in USDC, e.g., 2000): " MAX_COST_HUMAN

        # Convert to wei/smallest unit
        TOKEN_AMOUNT="${TOKEN_AMOUNT_HUMAN}000000000000000000"
        MAX_COST="${MAX_COST_HUMAN}000000"

        OPERATION=BUY_TOKENS \
        IDO_ADDRESS=$IDO_ADDRESS \
        USDC_ADDRESS=$USDC_ADDRESS \
        TOKEN_AMOUNT=$TOKEN_AMOUNT \
        MAX_COST=$MAX_COST \
        forge script script/Interact.s.sol:Interact \
            --rpc-url http://localhost:8545 \
            --broadcast \
            -vv
        ;;

    2)
        echo ""
        echo "=== Sell Tokens ==="
        read -p "IDO Address: " IDO_ADDRESS
        read -p "Token Amount (in tokens): " TOKEN_AMOUNT_HUMAN
        read -p "Min Refund (in USDC): " MIN_REFUND_HUMAN

        TOKEN_AMOUNT="${TOKEN_AMOUNT_HUMAN}000000000000000000"
        MIN_REFUND="${MIN_REFUND_HUMAN}000000"

        OPERATION=SELL_TOKENS \
        IDO_ADDRESS=$IDO_ADDRESS \
        TOKEN_AMOUNT=$TOKEN_AMOUNT \
        MIN_REFUND=$MIN_REFUND \
        forge script script/Interact.s.sol:Interact \
            --rpc-url http://localhost:8545 \
            --broadcast \
            -vv
        ;;

    3)
        echo ""
        echo "=== Rent Dataset ==="
        read -p "Rental Manager Address: " RENTAL_MANAGER
        read -p "Dataset Token Address: " DATASET_TOKEN
        read -p "USDC Address: " USDC_ADDRESS
        read -p "Hours: " HOURS

        OPERATION=RENT_DATASET \
        RENTAL_MANAGER=$RENTAL_MANAGER \
        DATASET_TOKEN=$DATASET_TOKEN \
        USDC_ADDRESS=$USDC_ADDRESS \
        HOURS=$HOURS \
        forge script script/Interact.s.sol:Interact \
            --rpc-url http://localhost:8545 \
            --broadcast \
            -vv
        ;;

    4)
        echo ""
        echo "=== Claim Dividends ==="
        read -p "Rental Pool Address: " RENTAL_POOL
        read -p "USDC Address: " USDC_ADDRESS

        OPERATION=CLAIM_DIVIDENDS \
        RENTAL_POOL=$RENTAL_POOL \
        USDC_ADDRESS=$USDC_ADDRESS \
        forge script script/Interact.s.sol:Interact \
            --rpc-url http://localhost:8545 \
            --broadcast \
            -vv
        ;;

    5)
        echo ""
        echo "=== Check Balances ==="
        read -p "User Address (default: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266): " USER
        USER=${USER:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}

        read -p "USDC Address: " USDC_ADDRESS
        read -p "Token Address (optional): " TOKEN_ADDRESS

        echo ""
        echo "USDC Balance:"
        cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | \
            awk '{printf "%.2f USDC\n", $1/1000000}'

        if [ ! -z "$TOKEN_ADDRESS" ]; then
            echo ""
            echo "Token Balance:"
            cast call $TOKEN_ADDRESS "balanceOf(address)(uint256)" $USER --rpc-url http://localhost:8545 | \
                awk '{printf "%.2f tokens\n", $1/1000000000000000000}'
        fi
        ;;

    6)
        echo "Exiting..."
        exit 0
        ;;

    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "Operation complete!"

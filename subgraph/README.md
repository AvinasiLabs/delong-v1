# DeLong Protocol Subgraph

This subgraph indexes all events from the DeLong Protocol smart contracts on Base Sepolia testnet.

## Architecture

### Indexed Contracts

**Main Contracts (Static addresses)**:
- **Factory** (`0x16bDb3338E65DC786Ca4bb49062D061Fc917cA1a`) - Entry point for dataset creation
- **RentalManager** (`0x95609b45a0f316edafa56fe3679570bd49be6476`) - Handles all rental operations
- **DAOTreasury** (`0x030906f8272d215f9f6033f9029aa60e6ae66f23`) - Treasury proposals
- **DAOGovernance** (`0x42e7f50e82be34c8244041c70b8cd79abc926891`) - Governance proposals

**Dynamic Contracts (Created per dataset)**:
- **IDO** - Token sale contract
- **DatasetToken** - ERC20 token
- **DatasetManager** - Dataset metadata and access control
- **RentalPool** - Dividend distribution

### Entities

The subgraph tracks the following main entities:

- `Dataset` - Core dataset information
- `IDO` - IDO contract state and fundraising data
- `User` - User aggregated statistics
- `TokenPurchase/TokenSale` - Trading activity
- `RentalAccess` - Rental purchases
- `UsageRecord` - Actual usage tracking
- `DividendClaim` - Dividend withdrawals
- `LPLock/LPWithdrawal` - LP liquidity tracking
- `TreasuryProposal/GovernanceProposal` - DAO governance
- `ProtocolStats` - Global protocol statistics

## Prerequisites

1. Node.js >= 18
2. The Graph CLI
3. Access to The Graph Studio (https://thegraph.com/studio/)

## Installation

```bash
cd subgraph
npm install -g @graphprotocol/graph-cli
npm install
```

## Configuration

### Step 1: Update Deployment Block

Before deploying, you need to update the `startBlock` in `subgraph.yaml` with the actual deployment blocks.

Find the deployment blocks:
```bash
# Get Factory deployment block
cast block-number --rpc-url $RPC_URL

# Or check on BaseScan:
# https://sepolia.basescan.org/address/0x16bDb3338E65DC786Ca4bb49062D061Fc917cA1a
```

Update all `startBlock: 18000000` entries in `subgraph.yaml` with the correct block number.

### Step 2: Generate Code

Generate AssemblyScript types from the ABIs and GraphQL schema:

```bash
npm run codegen
```

This will create the `generated/` directory with all type definitions.

### Step 3: Build

Compile the subgraph:

```bash
npm run build
```

This creates the `build/` directory with compiled AssemblyScript code.

## Deployment

### Option A: Deploy to The Graph Studio (Recommended)

The Graph Studio provides hosted infrastructure for your subgraph.

#### 1. Create a Subgraph on The Graph Studio

1. Go to https://thegraph.com/studio/
2. Connect your wallet
3. Click "Create a Subgraph"
4. Name it `delong-protocol`
5. Select network: `base-sepolia`

#### 2. Get Your Deploy Key

The Graph Studio will show you a deploy key like:
```
abc123def456...
```

#### 3. Authenticate

```bash
graph auth --studio <YOUR_DEPLOY_KEY>
```

#### 4. Deploy

```bash
npm run deploy
```

Or manually:
```bash
graph deploy --studio delong-protocol
```

#### 5. Publish

After deployment, go to The Graph Studio and click "Publish" to make your subgraph publicly queryable.

### Option B: Local Development

For local testing with Graph Node:

#### 1. Start Local Graph Node

```bash
# Clone graph-node repository
git clone https://github.com/graphprotocol/graph-node.git
cd graph-node/docker

# Start services
docker-compose up
```

#### 2. Create and Deploy Locally

```bash
npm run create-local
npm run deploy-local
```

## Querying the Subgraph

Once deployed, you can query the subgraph using GraphQL.

### Get Your Subgraph URL

After deployment, The Graph Studio will provide you with:
- **Development Query URL**: For testing (indexed by The Graph's hosted service)
- **Production Query URL**: After publishing (decentralized query URL)

Example URL format:
```
https://api.studio.thegraph.com/query/<ID>/delong-protocol/<VERSION>
```

### Example Queries

#### 1. Get All Datasets

```graphql
query GetDatasets {
  datasets(first: 10, orderBy: createdAt, orderDirection: desc) {
    id
    name
    symbol
    projectAddress
    totalRentalRevenue
    totalPurchases
    ido {
      status
      totalRaised
      currentPrice
    }
    createdAt
  }
}
```

#### 2. Get IDO Information

```graphql
query GetIDO($idoAddress: ID!) {
  ido(id: $idoAddress) {
    dataset {
      name
      symbol
    }
    status
    tokensSold
    totalRaised
    currentPrice
    startTime
    endTime
    purchases(first: 10, orderBy: timestamp, orderDirection: desc) {
      buyer {
        id
      }
      tokenAmount
      usdcAmount
      timestamp
    }
  }
}
```

#### 3. Get User Activity

```graphql
query GetUserActivity($userAddress: ID!) {
  user(id: $userAddress) {
    totalPurchases
    totalSales
    totalRentalSpent
    totalDividendsClaimed
    purchases(first: 10, orderBy: timestamp, orderDirection: desc) {
      dataset {
        name
      }
      tokenAmount
      usdcAmount
      timestamp
    }
    rentals(first: 10, orderBy: timestamp, orderDirection: desc) {
      dataset {
        name
      }
      hours
      totalCost
      timestamp
    }
  }
}
```

#### 4. Get Protocol Statistics

```graphql
query GetProtocolStats {
  protocolStats(id: "1") {
    totalDatasets
    activeDatasets
    totalTradingVolume
    totalRentalRevenue
    totalUsers
    activeIDOs
    launchedIDOs
    failedIDOs
  }
}
```

#### 5. Get Dataset with Full Details

```graphql
query GetDatasetDetails($datasetId: ID!) {
  dataset(id: $datasetId) {
    id
    name
    symbol
    metadataURI
    rentalPricePerHour
    projectAddress

    ido {
      status
      tokensSold
      totalRaised
      currentPrice
      initialPrice
    }

    token {
      totalSupply
      holdersCount
      isFrozen
    }

    totalPurchases
    totalSales
    totalRentalRevenue
    totalRentalAccesses

    purchases(first: 5, orderBy: timestamp, orderDirection: desc) {
      buyer {
        id
      }
      tokenAmount
      usdcAmount
      timestamp
    }

    rentals(first: 5, orderBy: timestamp, orderDirection: desc) {
      user {
        id
      }
      hours
      totalCost
      timestamp
    }
  }
}
```

#### 6. Get Rental Pool Dividends

```graphql
query GetPoolDividends($poolAddress: ID!) {
  rentalPool(id: $poolAddress) {
    dataset {
      name
    }
    accRevenuePerToken
    totalDividendsClaimed
    dividendClaims(first: 10, orderBy: timestamp, orderDirection: desc) {
      user {
        id
      }
      amount
      timestamp
    }
  }
}
```

## Frontend Integration

### Using Apollo Client (React)

```typescript
import { ApolloClient, InMemoryCache, gql } from '@apollo/client';

// Initialize client
const client = new ApolloClient({
  uri: 'https://api.studio.thegraph.com/query/<ID>/delong-protocol/<VERSION>',
  cache: new InMemoryCache(),
});

// Query datasets
const GET_DATASETS = gql`
  query GetDatasets {
    datasets(first: 10, orderBy: createdAt, orderDirection: desc) {
      id
      name
      symbol
      totalRentalRevenue
      ido {
        status
        currentPrice
      }
    }
  }
`;

// Usage in component
const { loading, error, data } = useQuery(GET_DATASETS);
```

### Using fetch (Vanilla JS)

```javascript
const SUBGRAPH_URL = 'https://api.studio.thegraph.com/query/<ID>/delong-protocol/<VERSION>';

async function queryDatasets() {
  const query = `
    query {
      datasets(first: 10, orderBy: createdAt, orderDirection: desc) {
        id
        name
        symbol
      }
    }
  `;

  const response = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ query }),
  });

  const { data } = await response.json();
  return data.datasets;
}
```

## Testing

The subgraph can be tested using Matchstick (Graph's testing framework):

```bash
npm run test
```

## Monitoring

After deployment, monitor your subgraph:

1. **The Graph Studio Dashboard**
   - View indexing status
   - Check query performance
   - Monitor error logs

2. **Health Check**
   ```bash
   curl https://api.studio.thegraph.com/query/<ID>/delong-protocol/<VERSION>/graphql
   ```

## Updating the Subgraph

When you need to update the subgraph (e.g., add new events or fix bugs):

1. Make changes to `schema.graphql`, `subgraph.yaml`, or `src/mapping.ts`
2. Run `npm run codegen` to regenerate types
3. Run `npm run build` to compile
4. Run `npm run deploy` to deploy the new version
5. The Graph will automatically create a new version while keeping the old one running
6. Publish the new version in The Graph Studio when ready

## Troubleshooting

### Common Issues

**Issue: "Failed to index block"**
- Check that the `startBlock` is correct
- Ensure contract addresses match deployed contracts
- Verify ABI files are up to date

**Issue: "Entity not found"**
- This usually means an entity is being loaded before it's created
- Check the order of event handlers
- Ensure proper null checks in mapping code

**Issue: "Type mismatch"**
- Run `npm run codegen` after schema changes
- Ensure all entity fields match the schema
- Check that BigInt, Bytes, and Address types are used correctly

**Issue: "Cannot convert null to BigInt"**
- Add null checks before accessing entity properties
- Initialize all BigInt fields to `BigInt.zero()`

### Getting Help

- The Graph Discord: https://discord.gg/graphprotocol
- The Graph Docs: https://thegraph.com/docs/
- DeLong Protocol: [Your Discord/Support Channel]

## License

MIT

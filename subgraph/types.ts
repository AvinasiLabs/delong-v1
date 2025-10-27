/**
 * TypeScript type definitions for DeLong Protocol Subgraph
 * Use these types in your frontend application for type-safe GraphQL queries
 */

// ========== Enum Types ==========

export enum IDOStatus {
  Active = "Active",
  Launched = "Launched",
  Failed = "Failed",
}

export enum DatasetStatus {
  Active = "Active",
  Inactive = "Inactive",
  Deprecated = "Deprecated",
}

export enum TreasuryProposalStatus {
  Pending = "Pending",
  Approved = "Approved",
  Rejected = "Rejected",
  Executed = "Executed",
  Cancelled = "Cancelled",
}

export enum GovernanceProposalStatus {
  Active = "Active",
  Executed = "Executed",
  Cancelled = "Cancelled",
}

export enum ProposalType {
  UpdatePrice = "UpdatePrice",
  UpdateManager = "UpdateManager",
  Other = "Other",
}

// ========== Entity Types ==========

export interface Dataset {
  id: string;
  datasetId: string;
  projectAddress: string;

  // Contract addresses
  ido: IDO;
  token: DatasetToken;
  manager: DatasetManager;
  pool: RentalPool;

  // Metadata
  name: string;
  symbol: string;
  metadataURI: string;

  // Rental pricing
  rentalPricePerHour: string;

  // IDO config
  alphaProject: string;
  k: string;
  betaLP: string;
  minRaiseRatio: string;
  initialPrice: string;

  // Timestamps
  createdAt: string;
  createdAtBlock: string;

  // Aggregated data
  totalPurchases: string;
  totalSales: string;
  totalRentalRevenue: string;
  totalRentalAccesses: string;

  // Relations
  purchases?: TokenPurchase[];
  sales?: TokenSale[];
  rentals?: RentalAccess[];
  usageRecords?: UsageRecord[];
}

export interface IDO {
  id: string;
  dataset: Dataset | string;

  // Status
  status: IDOStatus;

  // Token allocation
  salableTokens: string;
  projectTokens: string;
  targetTokens: string;
  tokensSold: string;

  // Pricing
  initialPrice: string;
  currentPrice: string;

  // Timestamps
  startTime: string;
  endTime: string;
  launchedAt?: string;
  failedAt?: string;

  // Fundraising
  totalRaised: string;
  targetRaise: string;

  // Relations
  purchases?: TokenPurchase[];
  sales?: TokenSale[];
}

export interface DatasetToken {
  id: string;
  dataset: Dataset | string;

  name: string;
  symbol: string;
  totalSupply: string;

  // Status
  isFrozen: boolean;
  unfrozenAt?: string;

  // Holders count
  holdersCount: string;

  // Relations
  holders?: TokenHolder[];
}

export interface DatasetManager {
  id: string;
  dataset: Dataset | string;

  metadataURI: string;
  projectAddress: string;

  // Status
  status: DatasetStatus;

  // Trial quota
  trialQuota: string;

  // Relations
  trialUsages?: TrialUsage[];
}

export interface RentalPool {
  id: string;
  dataset: Dataset | string;

  // Accumulated revenue per token
  accRevenuePerToken: string;

  // Total dividends claimed
  totalDividendsClaimed: string;

  // Relations
  dividendClaims?: DividendClaim[];
}

export interface User {
  id: string;

  // Aggregated data
  totalPurchases: string;
  totalSales: string;
  totalRentalSpent: string;
  totalDividendsClaimed: string;

  // Relations
  purchases?: TokenPurchase[];
  sales?: TokenSale[];
  rentals?: RentalAccess[];
  tokenHoldings?: TokenHolder[];
  dividendClaims?: DividendClaim[];
}

export interface TokenHolder {
  id: string;
  token: DatasetToken | string;
  user: User | string;

  balance: string;

  // Dividend tracking
  revenueDebt: string;
  pendingDividends: string;

  // First acquisition
  firstAcquiredAt: string;
  firstAcquiredAtBlock: string;
}

// ========== Transaction Types ==========

export interface TokenPurchase {
  id: string;
  dataset: Dataset | string;
  ido: IDO | string;
  buyer: User | string;

  tokenAmount: string;
  usdcAmount: string;
  pricePerToken: string;

  // Protocol fee
  protocolFee: string;

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

export interface TokenSale {
  id: string;
  dataset: Dataset | string;
  ido: IDO | string;
  seller: User | string;

  tokenAmount: string;
  usdcAmount: string;
  pricePerToken: string;

  // Protocol fee
  protocolFee: string;

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

export interface RentalAccess {
  id: string;
  dataset: Dataset | string;
  user: User | string;

  hours: string;
  totalCost: string;

  // Fee distribution
  protocolFee: string;
  dividendAmount: string;

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

export interface UsageRecord {
  id: string;
  dataset: Dataset | string;
  user: User | string;

  duration: string; // seconds

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

export interface TrialUsage {
  id: string;
  manager: DatasetManager | string;
  user: User | string;

  duration: string; // seconds
  remainingQuota: string;

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

export interface DividendClaim {
  id: string;
  pool: RentalPool | string;
  user: User | string;

  amount: string;

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

// ========== LP Lock Types ==========

export interface LPLock {
  id: string;
  dataset: Dataset | string;

  lpTokenAmount: string;
  lpTokenValue: string;
  projectAddress: string;
  lockedAt: string;

  // Unlock tracking
  accumulatedRevenue: string;
  withdrawnAmount: string;

  // Relations
  withdrawals?: LPWithdrawal[];
}

export interface LPWithdrawal {
  id: string;
  lpLock: LPLock | string;

  amount: string;
  accumulatedRevenue: string;

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

// ========== DAO Types ==========

export interface TreasuryProposal {
  id: string;
  proposalId: string;

  proposer: string;
  recipient: string;
  amount: string;
  description: string;

  status: TreasuryProposalStatus;

  submittedAt: string;
  approvedAt?: string;
  rejectedAt?: string;
  executedAt?: string;
  cancelledAt?: string;

  transactionHash: string;
}

export interface GovernanceProposal {
  id: string;
  proposalId: string;

  proposer: User | string;
  proposalType: ProposalType;
  datasetToken: string;
  targetAddress: string;

  // Price update specific
  newPrice?: string;

  // Voting
  votesFor: string;
  votesAgainst: string;
  totalVotes: string;

  status: GovernanceProposalStatus;

  createdAt: string;
  executedAt?: string;
  cancelledAt?: string;

  votes?: Vote[];
}

export interface Vote {
  id: string;
  proposal: GovernanceProposal | string;
  voter: User | string;

  support: boolean; // true = for, false = against
  votes: string; // voting power

  timestamp: string;
  blockNumber: string;
  transactionHash: string;
}

// ========== Protocol Stats ==========

export interface ProtocolStats {
  id: string;

  // Datasets
  totalDatasets: string;
  activeDatasets: string;

  // IDOs
  activeIDOs: string;
  launchedIDOs: string;
  failedIDOs: string;

  // Trading volume
  totalTradingVolume: string;
  totalProtocolFees: string;

  // Rentals
  totalRentalRevenue: string;
  totalRentalAccesses: string;

  // Users
  totalUsers: string;

  lastUpdated: string;
}

// ========== Query Response Types ==========

export interface GetDatasetsResponse {
  datasets: Dataset[];
}

export interface GetDatasetDetailsResponse {
  dataset: Dataset;
}

export interface GetActiveIDOsResponse {
  idOs: IDO[];
}

export interface GetIDODetailsResponse {
  ido: IDO;
}

export interface GetUserProfileResponse {
  user: User;
}

export interface GetUserHoldingsResponse {
  tokenHolders: TokenHolder[];
}

export interface GetRecentTradesResponse {
  tokenPurchases: TokenPurchase[];
  tokenSales: TokenSale[];
}

export interface GetRecentRentalsResponse {
  rentalAccesses: RentalAccess[];
}

export interface GetPoolDividendsResponse {
  rentalPool: RentalPool;
}

export interface GetProtocolStatsResponse {
  protocolStats: ProtocolStats;
}

export interface GetTreasuryProposalsResponse {
  treasuryProposals: TreasuryProposal[];
}

export interface GetGovernanceProposalsResponse {
  governanceProposals: GovernanceProposal[];
}

export interface GetLPLockResponse {
  lpLock: LPLock;
}

export interface GetTopLPLocksResponse {
  lpLocks: LPLock[];
}

// ========== Helper Types ==========

/**
 * Query variables for pagination
 */
export interface PaginationVars {
  first?: number;
  skip?: number;
}

/**
 * Query variables for time-based filtering
 */
export interface TimeRangeVars {
  from?: string;
  to?: string;
}

/**
 * Sort direction
 */
export type OrderDirection = "asc" | "desc";

/**
 * Common query variables
 */
export interface QueryVars extends PaginationVars {
  orderBy?: string;
  orderDirection?: OrderDirection;
}

// DeLong Protocol Subgraph - Raw Event Handlers
// 设计原则：只存储原始事件数据，不做任何聚合计算
// 聚合计算由后端的聚合计算服务完成

import { BigInt, log } from "@graphprotocol/graph-ts";
import {
  Dataset,
  IDOState,
  TokenPurchaseEvent,
  TokenSaleEvent,
  IDOLaunchedEvent,
  IDOFailedEvent,
  RefundClaimedEvent,
  AccessPurchasedEvent,
  UsageRecordedEvent,
  RentalDistributedEvent,
  RevenueAccumulatedEvent,
  LPLockedEvent,
  LPWithdrawnEvent,
  DividendClaimedEvent,
  RevenueAddedEvent,
  TokenTransferEvent,
  TokenUnfrozenEvent,
  MetadataUpdatedEvent,
  TrialUsageRecordedEvent,
  DatasetStatusUpdatedEvent,
  TreasuryProposalSubmittedEvent,
  TreasuryProposalStatusEvent,
  GovernanceProposalCreatedEvent,
  VoteCastEvent,
  GovernanceProposalStatusEvent,
} from "../generated/schema";

import { DatasetDeployed as DatasetDeployedEvent } from "../generated/Factory/Factory";

import {
  AccessPurchased as AccessPurchasedEventRaw,
  UsageRecorded as UsageRecordedEventRaw,
  RentalDistributed as RentalDistributedEventRaw,
  RevenueAccumulated as RevenueAccumulatedEventRaw,
  LPLocked as LPLockedEventRaw,
  LPWithdrawn as LPWithdrawnEventRaw,
} from "../generated/RentalManager/RentalManager";

import {
  TokensPurchased as TokensPurchasedEvent,
  TokensSold as TokensSoldEvent,
  IDOLaunched as IDOLaunchedEventRaw,
  IDOFailed as IDOFailedEventRaw,
  RefundClaimed as RefundClaimedEventRaw,
} from "../generated/templates/IDO/IDO";

import {
  Transfer as TransferEvent,
  Unfrozen as UnfrozenEvent,
} from "../generated/templates/DatasetToken/DatasetToken";

import {
  MetadataUpdated as MetadataUpdatedEventRaw,
  TrialUsageRecorded as TrialUsageRecordedEventRaw,
  StatusUpdated as StatusUpdatedEvent,
} from "../generated/templates/DatasetManager/DatasetManager";

import {
  RevenueAdded as RevenueAddedEventRaw,
  DividendsClaimed as DividendsClaimedEvent,
} from "../generated/templates/RentalPool/RentalPool";

import {
  ProposalSubmitted as ProposalSubmittedEvent,
  ProposalApproved as ProposalApprovedEvent,
  ProposalRejected as ProposalRejectedEvent,
  ProposalExecuted as ProposalExecutedEvent,
  ProposalCancelled as ProposalCancelledEvent,
} from "../generated/DAOTreasury/DAOTreasury";

import {
  ProposalCreated as ProposalCreatedEvent,
  VoteCast as VoteCastEventRaw,
  ProposalExecuted as GovernanceProposalExecutedEvent,
  ProposalCancelled as GovernanceProposalCancelledEvent,
} from "../generated/DAOGovernance/DAOGovernance";

import {
  IDO as IDOTemplate,
  DatasetToken as DatasetTokenTemplate,
  DatasetManager as DatasetManagerTemplate,
  RentalPool as RentalPoolTemplate,
} from "../generated/templates";

// Helper: Create unique event ID from tx hash and log index
function createEventId(txHash: string, logIndex: string): string {
  return txHash + "-" + logIndex;
}

// Helper: Get dataset ID from token address (stored when dataset is deployed)
// This is a lookup map we maintain
let tokenToDatasetMap = new Map<string, string>();

// ========== Factory Handlers ==========

export function handleDatasetDeployed(event: DatasetDeployedEvent): void {
  let datasetId = event.params.datasetId.toString();

  // Create Dataset entity
  let dataset = new Dataset(datasetId);
  dataset.datasetId = event.params.datasetId;
  dataset.projectAddress = event.params.projectAddress;
  dataset.idoAddress = event.params.ido;
  dataset.tokenAddress = event.params.token;
  dataset.managerAddress = event.params.manager;
  dataset.poolAddress = event.params.pool;
  dataset.createdAt = event.block.timestamp;
  dataset.createdAtBlock = event.block.number;
  dataset.transactionHash = event.transaction.hash;
  dataset.save();

  // Create IDOState
  let idoState = new IDOState(event.params.ido.toHexString());
  idoState.datasetId = datasetId;
  idoState.status = "Active";
  idoState.lastUpdatedAt = event.block.timestamp;
  idoState.lastUpdatedBlock = event.block.number;
  idoState.save();

  // Start indexing dynamic contracts
  IDOTemplate.create(event.params.ido);
  DatasetTokenTemplate.create(event.params.token);
  DatasetManagerTemplate.create(event.params.manager);
  RentalPoolTemplate.create(event.params.pool);

  log.info("Dataset deployed: datasetId={}, ido={}", [
    datasetId,
    event.params.ido.toHexString(),
  ]);
}

// ========== IDO Handlers ==========

export function handleTokensPurchased(event: TokensPurchasedEvent): void {
  // Find dataset ID by IDO address
  let idoState = IDOState.load(event.address.toHexString());
  if (idoState == null) {
    log.error("IDOState not found for address: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new TokenPurchaseEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = idoState.datasetId;
  eventEntity.idoAddress = event.address;
  eventEntity.buyer = event.params.buyer;
  eventEntity.tokenAmount = event.params.tokenAmount;
  eventEntity.usdcCost = event.params.usdcCost;
  eventEntity.fee = event.params.fee;
  eventEntity.newPrice = event.params.newPrice;
  eventEntity.timestamp = event.params.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleTokensSold(event: TokensSoldEvent): void {
  let idoState = IDOState.load(event.address.toHexString());
  if (idoState == null) {
    log.error("IDOState not found for address: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new TokenSaleEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = idoState.datasetId;
  eventEntity.idoAddress = event.address;
  eventEntity.seller = event.params.seller;
  eventEntity.tokenAmount = event.params.tokenAmount;
  eventEntity.usdcRefund = event.params.usdcRefund;
  eventEntity.fee = event.params.fee;
  eventEntity.newPrice = event.params.newPrice;
  eventEntity.timestamp = event.params.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleIDOLaunched(event: IDOLaunchedEventRaw): void {
  let idoState = IDOState.load(event.address.toHexString());
  if (idoState == null) {
    log.error("IDOState not found for address: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new IDOLaunchedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = idoState.datasetId;
  eventEntity.idoAddress = event.address;
  eventEntity.finalPrice = event.params.finalPrice;
  eventEntity.totalRaised = event.params.totalRaised;
  eventEntity.lpUSDC = event.params.lpUSDC;
  eventEntity.projectFunding = event.params.projectFunding;
  eventEntity.lpTokensLocked = event.params.lpTokensLocked;
  eventEntity.timestamp = event.params.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();

  // Update IDO status
  idoState.status = "Launched";
  idoState.lastUpdatedAt = event.block.timestamp;
  idoState.lastUpdatedBlock = event.block.number;
  idoState.save();
}

export function handleIDOFailed(event: IDOFailedEventRaw): void {
  let idoState = IDOState.load(event.address.toHexString());
  if (idoState == null) {
    log.error("IDOState not found for address: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new IDOFailedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = idoState.datasetId;
  eventEntity.idoAddress = event.address;
  eventEntity.soldTokens = event.params.soldTokens;
  eventEntity.usdcBalance = event.params.usdcBalance;
  eventEntity.refundRate = event.params.refundRate;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();

  // Update IDO status
  idoState.status = "Failed";
  idoState.lastUpdatedAt = event.block.timestamp;
  idoState.lastUpdatedBlock = event.block.number;
  idoState.save();
}

export function handleRefundClaimed(event: RefundClaimedEventRaw): void {
  let idoState = IDOState.load(event.address.toHexString());
  if (idoState == null) {
    log.error("IDOState not found for address: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new RefundClaimedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = idoState.datasetId;
  eventEntity.idoAddress = event.address;
  eventEntity.user = event.params.user;
  eventEntity.tokenAmount = event.params.tokenAmount;
  eventEntity.usdcAmount = event.params.usdcAmount;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== RentalManager Handlers ==========

export function handleAccessPurchased(event: AccessPurchasedEventRaw): void {
  // Need to find dataset by token address
  let dataset = findDatasetByToken(event.params.datasetToken.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.params.datasetToken.toHexString()]);
    return;
  }

  let eventEntity = new AccessPurchasedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.params.datasetToken;
  eventEntity.user = event.params.user;
  eventEntity.hours = event.params.hoursCount;
  eventEntity.totalCost = event.params.cost;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleUsageRecorded(event: UsageRecordedEventRaw): void {
  let dataset = findDatasetByToken(event.params.datasetToken.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.params.datasetToken.toHexString()]);
    return;
  }

  let eventEntity = new UsageRecordedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.params.datasetToken;
  eventEntity.user = event.params.user;
  eventEntity.rentalIndex = event.params.rentalIndex;
  eventEntity.additionalMinutes = event.params.additionalMinutes;
  eventEntity.totalUsedMinutes = event.params.totalUsedMinutes;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleRentalDistributed(event: RentalDistributedEventRaw): void {
  let dataset = findDatasetByToken(event.params.datasetToken.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.params.datasetToken.toHexString()]);
    return;
  }

  let eventEntity = new RentalDistributedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.params.datasetToken;
  eventEntity.totalAmount = event.params.totalAmount;
  eventEntity.protocolFee = event.params.protocolFee;
  eventEntity.dividend = event.params.dividend;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleRevenueAccumulated(event: RevenueAccumulatedEventRaw): void {
  let dataset = findDatasetByToken(event.params.datasetToken.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.params.datasetToken.toHexString()]);
    return;
  }

  let eventEntity = new RevenueAccumulatedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.params.datasetToken;
  eventEntity.additionalRevenue = event.params.additionalRevenue;
  eventEntity.totalRevenue = event.params.totalRevenue;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleLPLocked(event: LPLockedEventRaw): void {
  let dataset = findDatasetByToken(event.params.datasetToken.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.params.datasetToken.toHexString()]);
    return;
  }

  let eventEntity = new LPLockedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.params.datasetToken;
  eventEntity.lpToken = event.params.lpToken;
  eventEntity.projectAddress = event.params.projectAddress;
  eventEntity.amount = event.params.amount;
  eventEntity.lpValueUSDC = event.params.lpValueUSDC;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleLPWithdrawn(event: LPWithdrawnEventRaw): void {
  let dataset = findDatasetByToken(event.params.datasetToken.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.params.datasetToken.toHexString()]);
    return;
  }

  let eventEntity = new LPWithdrawnEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.params.datasetToken;
  eventEntity.amount = event.params.amount;
  eventEntity.accumulatedRevenue = event.params.totalClaimed;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== DatasetToken Handlers ==========

export function handleTransfer(event: TransferEvent): void {
  let dataset = findDatasetByToken(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.address.toHexString()]);
    return;
  }

  // Skip mint/burn
  let zeroAddress = "0x0000000000000000000000000000000000000000";
  if (
    event.params.from.toHexString() == zeroAddress ||
    event.params.to.toHexString() == zeroAddress
  ) {
    return;
  }

  let eventEntity = new TokenTransferEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.address;
  eventEntity.from = event.params.from;
  eventEntity.to = event.params.to;
  eventEntity.amount = event.params.value;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleUnfrozen(event: UnfrozenEvent): void {
  let dataset = findDatasetByToken(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for token: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new TokenUnfrozenEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.tokenAddress = event.address;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== DatasetManager Handlers ==========

export function handleMetadataUpdated(event: MetadataUpdatedEventRaw): void {
  let dataset = findDatasetByManager(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for manager: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new MetadataUpdatedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.managerAddress = event.address;
  eventEntity.oldURI = event.params.oldURI;
  eventEntity.newURI = event.params.newURI;
  eventEntity.version = event.params.version;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleTrialUsageRecorded(event: TrialUsageRecordedEventRaw): void {
  let dataset = findDatasetByManager(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for manager: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new TrialUsageRecordedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.managerAddress = event.address;
  eventEntity.user = event.params.user;
  eventEntity.usedSeconds = event.params.usedSeconds;
  eventEntity.totalUsed = event.params.totalUsed;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleStatusUpdated(event: StatusUpdatedEvent): void {
  let dataset = findDatasetByManager(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for manager: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new DatasetStatusUpdatedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.managerAddress = event.address;
  eventEntity.oldStatus = event.params.oldStatus;
  eventEntity.newStatus = event.params.newStatus;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== RentalPool Handlers ==========

export function handleRevenueAdded(event: RevenueAddedEventRaw): void {
  let dataset = findDatasetByPool(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for pool: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new RevenueAddedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.poolAddress = event.address;
  eventEntity.amount = event.params.amount;
  eventEntity.accRevenuePerToken = event.params.accRevenuePerToken;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleDividendsClaimed(event: DividendsClaimedEvent): void {
  let dataset = findDatasetByPool(event.address.toHexString());
  if (dataset == null) {
    log.warning("Dataset not found for pool: {}", [event.address.toHexString()]);
    return;
  }

  let eventEntity = new DividendClaimedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.datasetId = dataset.id;
  eventEntity.poolAddress = event.address;
  eventEntity.user = event.params.user;
  eventEntity.amount = event.params.amount;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== DAO Treasury Handlers ==========

export function handleProposalSubmitted(event: ProposalSubmittedEvent): void {
  let eventEntity = new TreasuryProposalSubmittedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.proposer = event.params.projectAddress;
  eventEntity.recipient = event.params.datasetToken;
  eventEntity.amount = event.params.amount;
  eventEntity.description = event.params.purpose;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleProposalApproved(event: ProposalApprovedEvent): void {
  let eventEntity = new TreasuryProposalStatusEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.status = "Approved";
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleProposalRejected(event: ProposalRejectedEvent): void {
  let eventEntity = new TreasuryProposalStatusEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.status = "Rejected";
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleProposalExecuted(event: ProposalExecutedEvent): void {
  let eventEntity = new TreasuryProposalStatusEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.status = "Executed";
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleProposalCancelled(event: ProposalCancelledEvent): void {
  let eventEntity = new TreasuryProposalStatusEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.status = "Cancelled";
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== DAO Governance Handlers ==========

export function handleProposalCreated(event: ProposalCreatedEvent): void {
  let eventEntity = new GovernanceProposalCreatedEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.proposer = event.params.proposer;
  eventEntity.proposalType = event.params.proposalType;
  eventEntity.targetContract = event.params.targetContract;
  eventEntity.description = event.params.description;
  eventEntity.newPrice = BigInt.fromI32(0); // Not in event, set to 0
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleVoteCast(event: VoteCastEventRaw): void {
  let eventEntity = new VoteCastEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.voter = event.params.voter;
  eventEntity.choice = event.params.choice;
  eventEntity.weight = event.params.weight;
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleGovernanceProposalExecuted(
  event: GovernanceProposalExecutedEvent
): void {
  let eventEntity = new GovernanceProposalStatusEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.status = "Executed";
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

export function handleGovernanceProposalCancelled(
  event: GovernanceProposalCancelledEvent
): void {
  let eventEntity = new GovernanceProposalStatusEvent(
    createEventId(event.transaction.hash.toHexString(), event.logIndex.toString())
  );
  eventEntity.proposalId = event.params.proposalId;
  eventEntity.status = "Cancelled";
  eventEntity.timestamp = event.block.timestamp;
  eventEntity.blockNumber = event.block.number;
  eventEntity.transactionHash = event.transaction.hash;
  eventEntity.save();
}

// ========== Helper Functions ==========

function findDatasetByToken(tokenAddress: string): Dataset | null {
  // Load all datasets and find matching token
  // Note: This is inefficient but The Graph doesn't support reverse lookup efficiently
  // In production, consider maintaining a separate lookup entity
  let datasets = new Array<Dataset>();
  let count = 0;
  while (count < 1000) {
    // Limit search to 1000 datasets
    let dataset = Dataset.load(count.toString());
    if (dataset != null && dataset.tokenAddress.toHexString() == tokenAddress) {
      return dataset;
    }
    count++;
  }
  return null;
}

function findDatasetByManager(managerAddress: string): Dataset | null {
  let count = 0;
  while (count < 1000) {
    let dataset = Dataset.load(count.toString());
    if (dataset != null && dataset.managerAddress.toHexString() == managerAddress) {
      return dataset;
    }
    count++;
  }
  return null;
}

function findDatasetByPool(poolAddress: string): Dataset | null {
  let count = 0;
  while (count < 1000) {
    let dataset = Dataset.load(count.toString());
    if (dataset != null && dataset.poolAddress.toHexString() == poolAddress) {
      return dataset;
    }
    count++;
  }
  return null;
}

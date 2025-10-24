# DeLong Protocol v1 - Deployment Scripts

本目录包含 DeLong Protocol v1 的部署和交互脚本。

## 快速开始

### 1. 启动本地节点

在一个终端窗口中启动 Anvil（Foundry 的本地以太坊节点）：

```bash
anvil
```

这将启动一个本地节点，监听 `http://localhost:8545`，并提供 10 个预配置的测试账户。

**重要**：保持此终端窗口开启！

### 2. 部署核心合约

在另一个终端窗口中，运行部署脚本：

```bash
# 方式1：使用便捷脚本
chmod +x script/*.sh
./script/deploy-local.sh

# 方式2：直接使用 forge
forge script script/Deploy.s.sol:Deploy \
    --rpc-url http://localhost:8545 \
    --broadcast \
    -vvvv
```

部署完成后，你会看到所有核心合约的地址：
- MockUSDC (测试用 USDC)
- Factory (数据集部署工厂)
- RentalManager (租赁管理器)
- DAOTreasury (DAO 金库)
- DAOGovernance (DAO 治理)

### 3. 部署数据集

使用 Factory 部署一个完整的数据集套件：

```bash
# 先更新 script/DeployDataset.s.sol 中的合约地址
# 地址可以在 broadcast/Deploy.s.sol/31337/run-latest.json 中找到

./script/deploy-dataset.sh
```

这将部署：
- DatasetToken (数据集代币)
- IDO (初始数据集发行)
- DatasetManager (数据集管理器)
- RentalPool (租赁池，用于分红)

## 详细使用

### 查看部署信息

部署记录保存在 `broadcast/` 目录下：

```bash
# 查看最新部署的交易
cat broadcast/Deploy.s.sol/31337/run-latest.json | jq

# 提取特定合约地址
cat broadcast/Deploy.s.sol/31337/run-latest.json | \
    jq -r '.transactions[] | select(.contractName == "Factory") | .contractAddress'
```

### 与合约交互

#### 方式1：使用交互脚本

```bash
./script/interact.sh
```

这会提供一个友好的交互界面，包括：
1. 购买代币（从 IDO）
2. 出售代币（回 IDO）
3. 租用数据集
4. 领取分红
5. 查看余额

#### 方式2：使用 cast 命令

```bash
# 读取数据（view 函数）
cast call <合约地址> "functionName(args)(returnType)" --rpc-url http://localhost:8545

# 示例：查看 IDO 当前价格
cast call 0x... "getCurrentPrice()(uint256)" --rpc-url http://localhost:8545

# 发送交易（需要私钥）
cast send <合约地址> "functionName(args)" \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 示例：购买代币
cast send <IDO地址> "buyTokens(uint256,uint256)" 1000000000000000000000 10000000000 \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

#### 方式3：使用 Interact.s.sol 脚本

```bash
# 购买代币
OPERATION=BUY_TOKENS \
IDO_ADDRESS=0x... \
USDC_ADDRESS=0x... \
TOKEN_AMOUNT=1000000000000000000000 \
MAX_COST=10000000000 \
forge script script/Interact.s.sol:Interact \
    --rpc-url http://localhost:8545 \
    --broadcast \
    -vv
```

## Anvil 默认账户

Anvil 提供 10 个测试账户，每个账户有 10,000 ETH：

```
Account #0: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (Deployer)
Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

Account #1: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (Protocol Treasury)
Private Key: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

Account #2: 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC (Project Address)
Private Key: 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
```

## 常用操作示例

### 1. 完整流程演示

```bash
# 1. 启动 Anvil
anvil

# 2. 部署核心合约
./script/deploy-local.sh

# 3. 记录合约地址（从输出或 broadcast 目录）
USDC=0x5FbDB2315678afecb367f032d93F642f64180aa3
FACTORY=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

# 4. 更新 DeployDataset.s.sol 中的地址并部署数据集
./script/deploy-dataset.sh

# 5. 记录数据集合约地址
IDO=0x...
DATASET_TOKEN=0x...
RENTAL_POOL=0x...

# 6. 购买代币
OPERATION=BUY_TOKENS \
IDO_ADDRESS=$IDO \
USDC_ADDRESS=$USDC \
TOKEN_AMOUNT=50000000000000000000000 \
MAX_COST=100000000000 \
forge script script/Interact.s.sol:Interact --rpc-url http://localhost:8545 --broadcast

# 7. 租用数据集
# (需要先在 script/Interact.s.sol 中配置 RENTAL_MANAGER 地址)

# 8. 领取分红
OPERATION=CLAIM_DIVIDENDS \
RENTAL_POOL=$RENTAL_POOL \
USDC_ADDRESS=$USDC \
forge script script/Interact.s.sol:Interact --rpc-url http://localhost:8545 --broadcast
```

### 2. 查询合约状态

```bash
# 查看用户的 USDC 余额
cast call $USDC "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --rpc-url http://localhost:8545

# 查看用户的代币余额
cast call $DATASET_TOKEN "balanceOf(address)(uint256)" 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --rpc-url http://localhost:8545

# 查看 IDO 当前价格
cast call $IDO "getCurrentPrice()(uint256)" --rpc-url http://localhost:8545

# 查看 IDO 状态 (0=Active, 1=Launched, 2=Failed)
cast call $IDO "status()(uint8)" --rpc-url http://localhost:8545

# 查看已售代币数量
cast call $IDO "soldTokens()(uint256)" --rpc-url http://localhost:8545

# 查看租赁池总收入
cast call $RENTAL_POOL "totalRevenue()(uint256)" --rpc-url http://localhost:8545

# 查看用户待领取分红
cast call $RENTAL_POOL "getPendingDividends(address)(uint256)" \
    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --rpc-url http://localhost:8545
```

### 3. 发送交易

```bash
# 铸造测试 USDC
cast send $USDC "mint(address,uint256)" \
    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    1000000000000 \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 授权 USDC
cast send $USDC "approve(address,uint256)" \
    $IDO \
    1000000000000 \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 购买代币
cast send $IDO "buyTokens(uint256,uint256)" \
    1000000000000000000000 \
    10000000000 \
    --rpc-url http://localhost:8545 \
    --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

## 故障排除

### 问题：Anvil 未运行

```
Error: Anvil is not running on port 8545
```

**解决方案**：在另一个终端运行 `anvil`

### 问题：Gas 不足

```
Error: insufficient funds for gas * price + value
```

**解决方案**：Anvil 账户默认有 10,000 ETH，这应该足够。检查是否使用了正确的账户。

### 问题：合约地址错误

```
Error: Contract not found at address
```

**解决方案**：
1. 确保已经部署了合约
2. 更新脚本中的合约地址
3. 检查 `broadcast/` 目录获取正确的地址

### 问题：Nonce 错误

```
Error: nonce too high
```

**解决方案**：重启 Anvil 节点以重置状态

## 环境变量

可以通过环境变量自定义部署：

```bash
# 使用自定义账户
export DEPLOYER=0x...
export PROTOCOL_TREASURY=0x...
export PROJECT_ADDRESS=0x...

# 然后运行部署
./script/deploy-local.sh
```

## 进阶：连接到测试网

部署到公共测试网（如 Sepolia）：

```bash
# 设置环境变量
export SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
export PRIVATE_KEY=your_private_key

# 部署
forge script script/Deploy.s.sol:Deploy \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    -vvvv
```

**注意**：测试网部署需要：
1. 测试网 ETH（从水龙头获取）
2. Infura/Alchemy API 密钥
3. Etherscan API 密钥（用于验证合约）

## 清理

重置 Anvil 状态：
1. 在 Anvil 终端按 `Ctrl+C` 停止
2. 重新运行 `anvil` 启动新实例
3. 重新部署合约

删除部署记录：

```bash
rm -rf broadcast/ cache/
```

## 更多资源

- [Foundry Book](https://book.getfoundry.sh/)
- [Cast 命令参考](https://book.getfoundry.sh/reference/cast/)
- [Forge 脚本指南](https://book.getfoundry.sh/tutorials/solidity-scripting)

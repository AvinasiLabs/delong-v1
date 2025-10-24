# DeLong Protocol v1 - 快速入门指南

本指南将带你在 **5 分钟内** 在本地部署并测试 DeLong Protocol v1。

## 前置条件

确保已安装 Foundry：

```bash
# 检查是否安装
forge --version

# 如果未安装，运行：
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## 🚀 5 分钟快速开始

### 第 1 步：启动本地区块链（30 秒）

打开终端窗口 1，运行：

```bash
anvil
```

你会看到：
```
Available Accounts
==================
(0) 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (10000 ETH)
(1) 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 (10000 ETH)
...
```

**保持此窗口开启！** 这是你的本地区块链。

### 第 2 步：部署核心合约（1 分钟）

打开终端窗口 2，在项目目录中运行：

```bash
./script/deploy-local.sh
```

你会看到类似输出：
```
=== DeLong Protocol v1 Deployment ===
Deployer: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
...
MockUSDC deployed at: 0x5FbDB2315678afecb367f032d93F642f64180aa3
Factory deployed at: 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
...
=== Deployment Complete ===
```

📝 **记下这些地址**，后面会用到！

### 第 3 步：更新配置并部署数据集（1 分钟）

编辑 `script/DeployDataset.s.sol`，更新合约地址：

```solidity
// 用第 2 步的实际地址替换
address public constant USDC_ADDRESS = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
address public constant FACTORY_ADDRESS = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
```

然后部署数据集：

```bash
./script/deploy-dataset.sh
```

你会看到：
```
=== Dataset Contract Suite ===
Dataset ID:       0
IDO:              0x...
DatasetToken:     0x...
RentalPool:       0x...
...
```

🎉 **恭喜！你的数据集已部署！**

### 第 4 步：购买代币（1 分钟）

使用交互脚本购买代币：

```bash
./script/interact.sh
```

选择 `1` 购买代币，输入：
- IDO Address: `<从第 3 步复制>`
- USDC Address: `<从第 2 步复制>`
- Token Amount: `1000` (购买 1000 个代币)
- Max Cost: `2000` (最多花费 2000 USDC)

### 第 5 步：查看余额（30 秒）

```bash
./script/interact.sh
```

选择 `5` 查看余额，你会看到：
- USDC 余额减少了
- 代币余额增加了

## 🎯 你已完成部署和基本测试！

## 接下来做什么？

### 选项 A：体验完整流程

```bash
# 1. 租用数据集（需要更多配置）
./script/interact.sh
# 选择 3，输入相关地址

# 2. 查看待领取分红
./script/interact.sh
# 选择 4
```

### 选项 B：使用 Cast 命令深入探索

```bash
# 设置地址变量（使用你的实际地址）
export IDO=0x...
export TOKEN=0x...
export USDC=0x...

# 查看 IDO 当前价格
cast call $IDO "getCurrentPrice()(uint256)" --rpc-url http://localhost:8545

# 查看 IDO 状态
cast call $IDO "status()(uint8)" --rpc-url http://localhost:8545

# 查看已售代币
cast call $IDO "soldTokens()(uint256)" --rpc-url http://localhost:8545

# 查看你的代币余额
cast call $TOKEN "balanceOf(address)(uint256)" \
    0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    --rpc-url http://localhost:8545
```

### 选项 C：运行完整测试

```bash
# 运行所有 123 个测试
forge test --summary

# 查看详细输出
forge test -vv

# 测试特定合约
forge test --match-contract IntegrationTest -vv
```

## 📚 详细文档

- **部署脚本说明**：查看 `script/README.md`
- **项目需求**：查看 `prompt/REQUIREMENT.md`
- **技术方案**：查看 `prompt/DEVELOPMENT.md`
- **测试报告**：运行 `forge test --gas-report`

## 🐛 遇到问题？

### Anvil 没运行
```
Error: connection refused
```
**解决**：确保在另一个终端运行了 `anvil`

### 地址不匹配
```
Error: Contract not found
```
**解决**：检查 `script/DeployDataset.s.sol` 中的地址是否正确

### 想重新开始
```bash
# 停止 Anvil (Ctrl+C)
# 重新启动
anvil

# 重新部署
./script/deploy-local.sh
```

## 💡 提示

1. **Anvil 账户**：默认使用 `0xf39F...2266`（账户 #0）
2. **私钥**：`0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`
3. **区块链状态**：每次重启 Anvil 都会重置
4. **Gas 费**：本地测试完全免费！

## 🎓 学习更多

### 理解架构

```
用户购买代币
    ↓
IDO (联合曲线定价)
    ↓
用户持有 DatasetToken
    ↓
用户租用数据集访问
    ↓
租金分配给代币持有者（分红）
    ↓
用户领取分红（USDC）
```

### 核心合约

- **Factory**: 部署完整的数据集套件
- **IDO**: 初始发行，使用联合曲线定价
- **DatasetToken**: ERC-20 代币，带冻结机制
- **RentalManager**: 管理租赁支付
- **RentalPool**: 分红分配给代币持有者
- **DAOTreasury**: 项目资金管理
- **DAOGovernance**: DAO 投票治理

## 🚀 准备好了？

现在你可以：
1. ✅ 部署合约到本地
2. ✅ 购买和出售代币
3. ✅ 查看余额和状态
4. ✅ 运行完整测试套件

**下一步**：阅读 `script/README.md` 了解更多高级功能！

# Cashmere CCTP Contracts

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Multi-Chain](https://img.shields.io/badge/Multi--Chain-EVM%20%7C%20Solana%20%7C%20Aptos%20%7C%20Sui-blue)]()

Cross-chain USDC transfer contracts powered by Circle's Cross-Chain Transfer Protocol (CCTP), enabling seamless USDC transfers across multiple blockchain networks with integrated gas drop functionality.

## 🌐 Overview

Cashmere CCTP is a comprehensive multi-chain solution that allows users to transfer USDC across different blockchain networks using Circle's CCTP infrastructure. The protocol supports native gas drops, flexible fee structures, and maintains consistent functionality across all supported chains.

### Supported Networks

- **EVM Chains** - Ethereum, Arbitrum, Optimism, Polygon, Base, Avalanche
- **Solana** - Solana mainnet and devnet
- **Aptos** - Aptos mainnet and testnet  
- **Sui** - Sui mainnet and testnet

### Goat LP

This repository also holds the source of the Goat LP contracts on Robinhood Chain (chain ID 4663): compounding,
auto-range and auto-exit for Uniswap v3 and v4 positions. See [goat-lp/README.md](goat-lp/README.md) for the
contracts, their addresses, build settings and licences.

## ✨ Features

- 🔄 **Cross-Chain USDC Transfers** - Seamlessly transfer USDC between different blockchain networks
- 💧 **Gas Drops** - Automatically provide native gas tokens on the destination chain
- 🎯 **Flexible Fee Structure** - Support for both native token and USDC fee payments
- 🛡️ **Signature Verification** - ED25519 signature validation for secure transfers
- ⚡ **Deadline Protection** - Time-based signature expiration for replay attack prevention
- 🔐 **Access Controls** - Role-based permissions for administrative functions
- 💰 **Fee Management** - Configurable percentage-based and static fees
- 🚫 **Reentrancy Protection** - Security measures against reentrancy attacks

## 🏗️ Architecture

### Contract Structure

```
cashmere-contracts/
├── evm/
│   └── src/
│       └── CashmereCCTP.sol          # EVM implementation
├── solana/
│   └── programs/
│       └── cashmere_cctp/            # Solana Anchor program
├── aptos/
│   └── sources/
│       └── transfer.move             # Aptos Move contract
└── sui/
    └── sources/
        └── transfer.move             # Sui Move contract
```

### Key Components

1. **Transfer Logic** - Core cross-chain transfer functionality
2. **Fee Management** - Dynamic fee calculation and collection
3. **Gas Drop System** - Native token distribution on destination chains
4. **Signature Verification** - Cryptographic validation of transfer requests
5. **Admin Controls** - Configuration management and emergency functions

## 🚀 Quick Start

### Prerequisites

- **EVM**: Solidity ^0.8.25, Hardhat/Foundry
- **Solana**: Anchor Framework, Rust
- **Aptos**: Aptos CLI, Move compiler
- **Sui**: Sui CLI, Move compiler

### Installation

#### EVM Contracts

```bash
cd evm
npm install
# Note: You'll need to add Circle's CCTP interface files
```

#### Solana Program

```bash
cd solana
anchor build
anchor test
```

#### Aptos Contract

```bash
cd aptos
aptos move compile
aptos move test
```

#### Sui Contract

```bash
cd sui
sui move build
sui move test
```

## 📋 Usage

### Basic Transfer Flow

1. **User initiates transfer** with destination chain, recipient, and amount
2. **Backend signs** transfer parameters with deadline and fee information
3. **Contract validates** signature and processes the transfer
4. **CCTP burns** USDC on source chain and mints on destination
5. **Gas drop** (if configured) provides native tokens to recipient

### Example Transfer (EVM)

```solidity
// Transfer 100 USDC from Ethereum to Arbitrum with gas drop
CashmereCCTP.TransferParams memory params = CashmereCCTP.TransferParams({
    amount: 100_000_000, // 100 USDC (6 decimals)
    destinationDomain: 3, // Arbitrum
    recipient: 0x..., // Recipient address
    solanaOwner: 0x..., // Solana owner (if applicable)
    fee: 1_000_000, // 1 USDC fee
    deadline: block.timestamp + 300, // 5 minutes
    gasDropAmount: 5_000_000, // 5 USDC worth of ETH
    isNative: false, // Fee in USDC
    signature: signatureBytes
});

contract.transfer{value: 0}(params);
```

### Domain IDs

| Chain | Domain ID |
|-------|-----------|
| Ethereum | 0 |
| Arbitrum | 3 |
| Optimism | 2 |
| Polygon | 7 |
| Base | 6 |
| Avalanche | 1 |
| Solana | 5 |
| Aptos | 9 |
| Sui | 8 |

## 🔧 Configuration

### Admin Functions

All contracts support the following administrative functions:

- `setFeeBP(uint256)` - Set percentage-based fee (max 1%)
- `setSigner(address)` - Update signature verification key
- `setMaxGasDrop(uint64)` - Configure maximum gas drop amounts
- `withdrawFees()` - Withdraw collected fees
- `transferOwnership()` - Transfer administrative control

### Fee Structure

- **Percentage Fee**: 0-100 basis points (0-1%) taken in USDC
- **Static Fee**: Fixed amount in USDC or native tokens
- **Gas Drop**: Native tokens provided to recipient (configurable limits)

## 🛡️ Security

### Security Features

- **Signature Verification**: ED25519 cryptographic validation
- **Deadline Protection**: Time-based signature expiration
- **Reentrancy Guards**: Protection against reentrancy attacks
- **Access Controls**: Role-based administrative permissions
- **Fee Limits**: Maximum configurable fee caps
- **Gas Drop Limits**: Configurable maximum gas drop amounts

### Best Practices

1. Always validate signatures before processing transfers
2. Use deadline parameters to prevent replay attacks
3. Configure appropriate fee and gas drop limits
4. Regularly rotate signing keys
5. Monitor for unusual transaction patterns

## 🔗 Integration

### Backend Integration

The contracts require a backend service to:

1. **Generate Signatures** - Sign transfer parameters with ED25519
2. **Manage Deadlines** - Provide time-limited signatures
3. **Calculate Fees** - Determine appropriate fee structures
4. **Monitor Transfers** - Track cross-chain transaction status

### Frontend Integration

Use the contracts with popular Web3 libraries:

```javascript
// Web3.js example
const contract = new web3.eth.Contract(ABI, CONTRACT_ADDRESS);
await contract.methods.transfer(params).send({from: userAddress});

// Ethers.js example
const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, signer);
await contract.transfer(params);
```

## 📄 Contract Addresses

### Mainnet Deployments

| Network | Contract Address | Status |
|---------|------------------|---------|
| Ethereum | `TBD` | 🔄 Pending |
| Arbitrum | `TBD` | 🔄 Pending |
| Optimism | `TBD` | 🔄 Pending |
| Polygon | `TBD` | 🔄 Pending |
| Base | `TBD` | 🔄 Pending |
| Avalanche | `TBD` | 🔄 Pending |
| Solana | `TBD` | 🔄 Pending |
| Aptos | `TBD` | 🔄 Pending |
| Sui | `TBD` | 🔄 Pending |

### Testnet Deployments

Available for development and testing purposes. Contact the team for testnet addresses.

## 🧪 Testing

### Running Tests

```bash
# EVM tests
cd evm && npm test

# Solana tests
cd solana && anchor test

# Aptos tests
cd aptos && aptos move test

# Sui tests
cd sui && sui move test
```

### Test Coverage

- ✅ Basic transfer functionality
- ✅ Fee calculation and collection
- ✅ Gas drop mechanisms
- ✅ Signature verification
- ✅ Admin functions
- ✅ Error handling
- ✅ Edge cases and boundary conditions

## 🤝 Contributing

We welcome contributions! Please follow these guidelines:

1. **Fork** the repository
2. **Create** a feature branch (`git checkout -b feature/amazing-feature`)
3. **Commit** your changes (`git commit -m 'Add amazing feature'`)
4. **Push** to the branch (`git push origin feature/amazing-feature`)
5. **Open** a Pull Request

### Development Guidelines

- Follow the existing code style and patterns
- Add comprehensive tests for new features
- Update documentation as needed
- Ensure all tests pass before submitting

## 🐛 Bug Reports

If you discover a security vulnerability, please send an email to [cashmereprotocol@gmail.com]. All security vulnerabilities will be promptly addressed.

For non-security issues, please open a GitHub issue with:
- Clear description of the problem
- Steps to reproduce
- Expected vs actual behavior
- Contract addresses and transaction hashes (if applicable)

## 📚 Documentation

### Additional Resources

- [Circle CCTP Documentation](https://developers.circle.com/cctp)
- [Solana Anchor Book](https://book.anchor-lang.com/)
- [Aptos Move Documentation](https://move-language.github.io/move/)
- [Sui Move Documentation](https://docs.sui.io/concepts/sui-move-concepts)

### API Reference

Detailed API documentation for each contract is available in the respective source files.

## 🎯 Roadmap

- [ ] Additional EVM chain support
- [ ] Enhanced gas estimation
- [ ] Batch transfer functionality
- [ ] Advanced fee structures
- [ ] Governance token integration
- [ ] Mobile SDK development

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Circle** - For providing the CCTP infrastructure
- **Anchor** - Solana development framework
- **OpenZeppelin** - EVM security libraries
- **Move** - Smart contract language for Aptos and Sui

---

**⚠️ Disclaimer**: This software is provided "as is" without warranties. Use at your own risk. Always conduct thorough testing before deploying to production.

For questions and support, please open an issue or contact the development team. 
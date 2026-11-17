# Goat LP contracts

> Goat LP is experimental. Use small amounts.

Goat LP manages Uniswap v3 and v4 liquidity positions on Robinhood Chain mainnet (chain ID 4663). It offers one-click
compounding, and three automations that a position's owner turns on for that position: auto-compound, auto-range and
auto-exit. Goat-run keepers trigger the runs, and Cashmere pays their gas.

This folder holds the exact source verified on the explorer for each of the 13 contracts.

Earlier contracts (until 17 November 2026): source at commit
[2eb57df](https://github.com/cashmere-prod/contracts-prod/tree/2eb57dfda452b3f5f7aed2b65f6455814fd06be4/goat-lp).

None of these contracts is upgradeable: no proxy, no delegatecall.

## Contracts

### Compounding

| Contract | Source | Address | What it does |
| --- | --- | --- | --- |
| `GoatSelfCompoundor` | [compoundor/contracts/GoatSelfCompoundor.sol](compoundor/contracts/GoatSelfCompoundor.sol) | [`0xC3A1b88F5fa6B504b387c7109a978bf4358a7B25`](https://robin.etherscan.io/address/0xC3A1b88F5fa6B504b387c7109a978bf4358a7B25) | One-click compound on Uniswap v3. Takes the position, adds its fees back, takes 10% of what was added back, and returns the position in the same transaction |
| `GoatAutoCompoundV3` | [compoundor/contracts/GoatAutoCompoundV3.sol](compoundor/contracts/GoatAutoCompoundV3.sol) | [`0x677690f3Fe316dea300e42434c50aca25F8C2223`](https://robin.etherscan.io/address/0x677690f3Fe316dea300e42434c50aca25F8C2223) | Auto-compound on v3, through the owner's permission for one position. It can only collect fees, swap part of them and add liquidity back; it cannot remove liquidity |
| `GoatV4Compoundor` | [v4-compoundor/src/GoatV4Compoundor.sol](v4-compoundor/src/GoatV4Compoundor.sol) | [`0x98658FA3fe09195eD7b6F838D2627F2e840B8D50`](https://robin.etherscan.io/address/0x98658FA3fe09195eD7b6F838D2627F2e840B8D50) | The same on Uniswap v4 |
| `GoatAutoCompoundV4` | [v4-compoundor/src/GoatAutoCompoundV4.sol](v4-compoundor/src/GoatAutoCompoundV4.sol) | [`0x3aEE50cf7e605C77FD8FE26e5BAF3B090819D840`](https://robin.etherscan.io/address/0x3aEE50cf7e605C77FD8FE26e5BAF3B090819D840) | Auto-compound on v4. Its only power is to send the position to `GoatV4Compoundor` and check that it came back; each run uses one message the owner signed |
| `GoatPriceAnchor` | [v4-compoundor/src/GoatPriceAnchor.sol](v4-compoundor/src/GoatPriceAnchor.sol) | [`0x3cdcD4F72Fa74721953e4D94C4f571D623235e55`](https://robin.etherscan.io/address/0x3cdcD4F72Fa74721953e4D94C4f571D623235e55) | The outside price for compounds: a Chainlink feed, or the average price of a deep pool |

### Auto-range and auto-exit on Uniswap v3

`AutoRange` and `AutoExit` are Revert Finance's contracts with changes for Robinhood Chain only: price checks against an
outside price, re-centring on that price, a fixed 0.15% fee that can only be lowered, and a table of listed pairs.
Revert Finance has not reviewed these versions.

| Contract | Source | Address | What it does |
| --- | --- | --- | --- |
| `AutoRange` | [v3-automation/src/transformers/AutoRange.sol](v3-automation/src/transformers/AutoRange.sol) | [`0x6D31b7399126732426fAb7ee2fF5e20cF6E95Fd3`](https://robin.etherscan.io/address/0x6D31b7399126732426fAb7ee2fF5e20cF6E95Fd3) | Moves a v3 position when its trigger is hit; the new position goes to the owner |
| `AutoExit` | [v3-automation/src/automators/AutoExit.sol](v3-automation/src/automators/AutoExit.sol) | [`0xA5CC5A1F3Ba1Ed949EdAfEAdD021d0d0F7B670CC`](https://robin.etherscan.io/address/0xA5CC5A1F3Ba1Ed949EdAfEAdD021d0d0F7B670CC) | Closes a v3 position at the owner's level; everything goes to the owner |
| `GoatPairTable` | [v3-automation/src/goat/GoatPairTable.sol](v3-automation/src/goat/GoatPairTable.sol) | [`0x6a56E90e9d5d63fFFA024BEcfe9e43B610591160`](https://robin.etherscan.io/address/0x6a56E90e9d5d63fFFA024BEcfe9e43B610591160) | Which pairs and fee tiers v3 automation may use, their price sources and swap limits |

### Auto-range and auto-exit on Uniswap v4

| Contract | Source | Address | What it does |
| --- | --- | --- | --- |
| `GoatV4Steward` | [v4-automation/src/GoatV4Steward.sol](v4-automation/src/GoatV4Steward.sol) | [`0x64eFB4C6b95c0AaEd09F85f0918B22eBa51E4F08`](https://robin.etherscan.io/address/0x64eFB4C6b95c0AaEd09F85f0918B22eBa51E4F08) | Decides: the owner's rule, the price checks, the trigger and the new range |
| `GoatV4StewardEngine` | [v4-automation/src/GoatV4StewardEngine.sol](v4-automation/src/GoatV4StewardEngine.sol) | [`0xE772E4dFE436F14F3Bec6733Dc29A47A2741DDB2`](https://robin.etherscan.io/address/0xE772E4dFE436F14F3Bec6733Dc29A47A2741DDB2) | Executes. The one contract an owner allows for v4 auto-range and auto-exit; it takes orders only from the Steward and holds nothing between calls. Created by the Steward |
| `GoatV4PairRegistry` | [v4-automation/src/GoatV4PairRegistry.sol](v4-automation/src/GoatV4PairRegistry.sol) | [`0xa5685AF166e3529FEd41419ae26c02AA3Ac929e9`](https://robin.etherscan.io/address/0xa5685AF166e3529FEd41419ae26c02AA3Ac929e9) | Which v4 pools automation may use, their price sources, and reviewed hooks pinned by code |
| `GoatV4PokeOracle` | [v4-automation/src/oracle/GoatV4PokeOracle.sol](v4-automation/src/oracle/GoatV4PokeOracle.sol) | [`0xeb026A134a21224381b955c32bf8AF9aF1988e8D`](https://robin.etherscan.io/address/0xeb026A134a21224381b955c32bf8AF9aF1988e8D) | Average-price history for listed v4 pools that serve as a pair's price source. Only Goat's registered price readers count toward it; anyone else's reading is kept only as a warning signal |
| `GoatV4SourceMeter` | [v4-automation/src/meter/GoatV4SourceMeter.sol](v4-automation/src/meter/GoatV4SourceMeter.sol) | [`0xDcD0605c8eB1E7fE76688FB73FE98D4656985793`](https://robin.etherscan.io/address/0xDcD0605c8eB1E7fE76688FB73FE98D4656985793) | Checks a price source's depth and history when a pool is listed. No owner, no settings |

Roles, the fee address, the Uniswap contracts Goat LP calls, and what an owner allows for each automation are on the
[Contracts page of the docs](https://docs.cashmere.exchange/goat-lp/contracts).

## Build settings

| Folder | Compiler | Optimizer | EVM version | via-IR | Metadata |
| --- | --- | --- | --- | --- | --- |
| `compoundor/` | solc 0.7.6+commit.7338295f | on, 800 runs | istanbul | no | IPFS hash |
| `v4-compoundor/` | solc 0.8.26+commit.8a97fa7a | on, 500 runs | cancun | yes | none (no CBOR tail) |
| `v3-automation/` | solc 0.8.24+commit.e11b9ed9 | on, 200 runs | cancun | no | IPFS hash |
| `v4-automation/` | solc 0.8.26+commit.8a97fa7a | on, 500 runs | cancun | yes | IPFS hash |

Third-party libraries are not copied here, except the OpenZeppelin files vendored under
`compoundor/contracts/external/openzeppelin/`. The builds used:

- `v3-automation/`: OpenZeppelin Contracts 4.9.6, Uniswap v3-core 1.0.1 and v3-periphery 1.4.2 (their solc 0.8
  versions), Permit2 1.0.0, and the Chainlink `AggregatorV3Interface`, Uniswap `IUniversalRouter` and `IWETH9`
  interfaces.
- `v4-compoundor/` and `v4-automation/`: Uniswap v4-periphery 1.0.4 with v4-core 1.0.2.

Import paths follow these remappings:

- `v3-automation/`: `@openzeppelin/=lib/openzeppelin-contracts/`, `@uniswap/v3-core/=lib/v3-core/`,
  `@uniswap/v3-periphery/=lib/v3-periphery/`, `permit2/=lib/permit2/src/`, `v3-core/=lib/v3-core/contracts/`,
  `v3-periphery/=lib/v3-periphery/contracts/`.
- `v4-compoundor/` and `v4-automation/`: `@uniswap/v4-core/=lib/v4-periphery/lib/v4-core/`,
  `@uniswap/v4-periphery/=lib/v4-periphery/`, `v4-core/=lib/v4-periphery/lib/v4-core/src/`,
  `permit2/=lib/v4-periphery/lib/permit2/`,
  `@openzeppelin/contracts/=lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/`.

## Licences

- `compoundor/`: MIT. `GoatSelfCompoundor` is a fork of Revert Finance's compoundor; `LICENSE` keeps Revert's copyright
  notice.
- `v4-compoundor/`: MIT, as each file's SPDX header says.
- `v3-automation/`: `AutoRange`, `AutoExit` and the files they share (`Automator`, `Transformer`, `IVault`, `Constants`,
  `Swapper`) come from Revert Finance's lend repository and keep its BUSL-1.1 header; `LICENSE` is that licence text.
  The `src/goat/` files are GPL-2.0-or-later; `COPYING` is that licence text.
- `v4-automation/`: MIT (`LICENSE`).

## More

- Docs: [Goat LP overview](https://docs.cashmere.exchange/goat-lp/overview) and
  [contracts](https://docs.cashmere.exchange/goat-lp/contracts)
- App: [app.cashmere.exchange](https://app.cashmere.exchange)

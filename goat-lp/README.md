# Goat LP contracts

> Goat LP is experimental. Use small amounts.

Goat LP manages Uniswap v3 and v4 liquidity positions on Robinhood Chain mainnet (chain ID 4663). It offers one-click
compounding, and three automations that a position's owner turns on for that position: auto-compound, auto-range and
auto-exit. Goat-run keepers trigger the runs, and Cashmere pays their gas.

This folder holds the source of the 13 contracts Goat LP runs, with the project files they import. The comments were
rewritten in English for this repository; the code is unchanged. Compiled with the settings below, each contract gives
the same runtime code as the contract at its address; only the metadata hash at the end of the code differs, because it
covers the comments. The exact source as compiled, original comments included, is published on the explorer at each
address.

None of these contracts is upgradeable: no proxy, no delegatecall.

## Contracts

### Compounding

| Contract | Source | Address | What it does |
| --- | --- | --- | --- |
| `GoatSelfCompoundor` | [compoundor/contracts/GoatSelfCompoundor.sol](compoundor/contracts/GoatSelfCompoundor.sol) | [`0x4D0D364EB62be5FcFdc88c56E64ff1eEbaD99DaA`](https://robin.etherscan.io/address/0x4D0D364EB62be5FcFdc88c56E64ff1eEbaD99DaA) | One-click compound on Uniswap v3. Takes the position, adds its fees back, takes 10% of what was added back, and returns the position in the same transaction |
| `GoatAutoCompoundV3` | [compoundor/contracts/GoatAutoCompoundV3.sol](compoundor/contracts/GoatAutoCompoundV3.sol) | [`0x4A036a2d8FD1d2C0110A9d775ae269fFE6Ea8390`](https://robin.etherscan.io/address/0x4A036a2d8FD1d2C0110A9d775ae269fFE6Ea8390) | Auto-compound on v3, through the owner's permission for one position. It can only collect fees, swap part of them and add liquidity back; it cannot remove liquidity |
| `GoatV4Compoundor` | [v4-compoundor/src/GoatV4Compoundor.sol](v4-compoundor/src/GoatV4Compoundor.sol) | [`0x307db4605691Ca81bAe9DD162de6F8De319224f5`](https://robin.etherscan.io/address/0x307db4605691Ca81bAe9DD162de6F8De319224f5) | The same on Uniswap v4 |
| `GoatAutoCompoundV4` | [v4-compoundor/src/GoatAutoCompoundV4.sol](v4-compoundor/src/GoatAutoCompoundV4.sol) | [`0xb0d066E7E9B21c3AbDCe9b26A767155F48Ed0500`](https://robin.etherscan.io/address/0xb0d066E7E9B21c3AbDCe9b26A767155F48Ed0500) | Auto-compound on v4. Its only power is to send the position to `GoatV4Compoundor` and check that it came back; each run uses one message the owner signed |
| `GoatPriceAnchor` | [v4-compoundor/src/GoatPriceAnchor.sol](v4-compoundor/src/GoatPriceAnchor.sol) | [`0x5799d99837d2736C6506AD5EE0727968B708A566`](https://robin.etherscan.io/address/0x5799d99837d2736C6506AD5EE0727968B708A566) | The outside price for compounds: a Chainlink feed, or the average price of a deep pool |

### Auto-range and auto-exit on Uniswap v3

`AutoRange` and `AutoExit` are Revert Finance's contracts with changes for Robinhood Chain only: price checks against an
outside price, re-centring on that price, a fixed 0.15% fee that can only be lowered, and a table of listed pairs.
Revert Finance has not reviewed these versions.

| Contract | Source | Address | What it does |
| --- | --- | --- | --- |
| `AutoRange` | [v3-automation/src/transformers/AutoRange.sol](v3-automation/src/transformers/AutoRange.sol) | [`0xF0436e6B378e7d4b1Fb17860673C091A32Fb19cD`](https://robin.etherscan.io/address/0xF0436e6B378e7d4b1Fb17860673C091A32Fb19cD) | Moves a v3 position when its trigger is hit; the new position goes to the owner |
| `AutoExit` | [v3-automation/src/automators/AutoExit.sol](v3-automation/src/automators/AutoExit.sol) | [`0xe337A443237a9eA7ED3b0610F70c24c040438161`](https://robin.etherscan.io/address/0xe337A443237a9eA7ED3b0610F70c24c040438161) | Closes a v3 position at the owner's level; everything goes to the owner |
| `GoatPairTable` | [v3-automation/src/goat/GoatPairTable.sol](v3-automation/src/goat/GoatPairTable.sol) | [`0xbBF00DD403BFf43400ed3D32a29cF4eC580026De`](https://robin.etherscan.io/address/0xbBF00DD403BFf43400ed3D32a29cF4eC580026De) | Which pairs and fee tiers v3 automation may use, their price sources and swap limits |

### Auto-range and auto-exit on Uniswap v4

| Contract | Source | Address | What it does |
| --- | --- | --- | --- |
| `GoatV4Steward` | [v4-automation/src/GoatV4Steward.sol](v4-automation/src/GoatV4Steward.sol) | [`0xBb6494D891bd9cCCf11ADd32FD61Afe246164b3d`](https://robin.etherscan.io/address/0xBb6494D891bd9cCCf11ADd32FD61Afe246164b3d) | Decides: the owner's rule, the price checks, the trigger and the new range |
| `GoatV4StewardEngine` | [v4-automation/src/GoatV4StewardEngine.sol](v4-automation/src/GoatV4StewardEngine.sol) | [`0xD12D46c9d3B1FE463895A20daD19F3cae5584892`](https://robin.etherscan.io/address/0xD12D46c9d3B1FE463895A20daD19F3cae5584892) | Executes. The one contract an owner allows for v4 auto-range and auto-exit; it takes orders only from the Steward and holds nothing between calls. Created by the Steward |
| `GoatV4PairRegistry` | [v4-automation/src/GoatV4PairRegistry.sol](v4-automation/src/GoatV4PairRegistry.sol) | [`0x92f449da205552Eadbb51C05888EEDE1657B4048`](https://robin.etherscan.io/address/0x92f449da205552Eadbb51C05888EEDE1657B4048) | Which v4 pools automation may use, their price sources, and reviewed hooks pinned by code |
| `GoatV4PokeOracle` | [v4-automation/src/oracle/GoatV4PokeOracle.sol](v4-automation/src/oracle/GoatV4PokeOracle.sol) | [`0xadeA4C7d46a2d3Fb442C4079FC236B262b4b2b50`](https://robin.etherscan.io/address/0xadeA4C7d46a2d3Fb442C4079FC236B262b4b2b50) | Average-price history for listed v4 pools that serve as a pair's price source |
| `GoatV4SourceMeter` | [v4-automation/src/meter/GoatV4SourceMeter.sol](v4-automation/src/meter/GoatV4SourceMeter.sol) | [`0xd7dB57c254eA350215Fb07ab386AA5E909CD7205`](https://robin.etherscan.io/address/0xd7dB57c254eA350215Fb07ab386AA5E909CD7205) | Checks a price source's depth and history when a pool is listed. No owner, no settings |

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

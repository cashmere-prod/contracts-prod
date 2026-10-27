// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Part of Goat LP, not derived from Revert Finance. Shared logic of AutoRange and AutoExit on Robinhood Chain (4663):
// compile-time constants, the link to the pair table (GoatPairTable), the anchor gate, the source short-TWAP and spot
// gate, route and depth checks, swap-budget use and the "only the needed swap" checks. Only AutoRange and AutoExit
// inherit it; it has no constructor. This build is for chain 4663 only: _checkRobinhoodDeployment reverts with
// WrongChain anywhere else.

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "v3-core/interfaces/IUniswapV3Pool.sol";
// factory.getPool for route hops
import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";
// unit-liquidity amounts for the needed-swap bounds
import "v3-periphery/libraries/LiquidityAmounts.sol";

import "../utils/Constants.sol";
// pair table (feeds, bounds, age, market hours, veto pool, gate G)
import "./GoatPairTable.sol";

abstract contract GoatRobinhood is Constants {
    // ---- chain identity and route core: WETH/USDG (the first founding pair; the intermediate hop tokens) ----
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73; // 18
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; // 6

    // ---- pair table: the owner binds it once (setPairTable) and it cannot change afterwards. Adding or changing a
    //      row takes a 24 h timelock in the table, removing is instant. No anchored flow runs before it is bound
    //      (InvalidPool, fail closed). ----
    GoatPairTable public pairTable;
    event PairTableSet(address table);
    // The bound table's CODE is pinned: keccak256 of its DEPLOYED runtime code without the trailing CBOR metadata. The
    // metadata (source paths, comments, remappings) is never executed and depends on where the code was compiled; the
    // executed code does not. The hash is taken from the deployed code (address(t).code), not from a build artifact:
    // for GoatPairTable's immutables (clFoundingHash, ncFoundingHash) the artifact holds zeros where the deployed code
    // holds their values. The constructor takes no arguments and the founding data are compile-time constants
    // (GoatFoundingPairs, GoatFoundingNc), so every genuine table from the same build has the same deployed code; the
    // constant pins the code AND the founding data together. If GoatPairTable.sol or the founding lists change, this
    // constant must be recomputed from the final build (solc 0.8.24, optimizer 200 runs, cancun).
    bytes32 public constant PAIR_TABLE_CODE_HASH = 0x6a38e9172508d39ba2433d67cafac3d13fb36367910258ed7f3faff08ef12e56;

    // ---- veto: TWAP window and K bounds (constructor). Each pair's veto pool comes from the table; VETO_POOL is only
    //      used for the chain identity check at deployment (factory.getPool(WETH, USDG, 100)) ----
    IUniswapV3Pool public constant VETO_POOL = IUniswapV3Pool(0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca);
    uint32 internal constant VETO_TWAP_SECONDS_MIN = 900;
    uint32 internal constant VETO_TWAP_SECONDS_MAX = 1080;
    uint16 internal constant VETO_MAX_TICK_DIFFERENCE = 150; // K
    // source short-TWAP gate: the 60 s and 10 s TWAPs of the source pool (CL: veto pool, NC: reference) must be within
    // G of the anchor. A price moved in the current second does not show in these TWAPs yet (observations record the
    // tick from before the move), so the gate cannot be passed atomically.
    uint32 internal constant GATE_TWAP_SLOW = 60;
    uint32 internal constant GATE_TWAP_FAST = 10;
    // slippage cap of 1% (against the anchor, after the pool fee is deducted)
    uint64 public constant MAX_SLIPPAGE_X64 = uint64(Q64 / 100);

    // ---- swap path: Universal Router 2.1.1 only; hop tokens only the pair's own tokens and WETH/USDG; hop pools in a
    //      canonical v3 fee tier and registered in the factory; the 0x AllowanceHolder path is DISABLED ----
    address public constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904; // Universal Router 2.1.1
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; // NPM.factory()
    // UR Commands.sol: only V3_SWAP_EXACT_IN (0x00) and SWEEP (0x04) without flags are accepted. The allow-revert form
    // (0x80|x) and the 0x40|x forms that UR would mask to 0x00 are REJECTED as well (exact match); every other command
    // (TRANSFER, PAY_PORTION, V2/V4 swaps, Permit2, WRAP/UNWRAP, EXECUTE_SUB_PLAN, ...) is rejected
    bytes1 internal constant UR_V3_SWAP_EXACT_IN = 0x00;
    bytes1 internal constant UR_SWEEP = 0x04;
    address internal constant UR_MSG_SENDER = address(1); // ActionConstants.MSG_SENDER: the caller of UR (this contract)
    uint256 internal constant UR_CONTRACT_BALANCE = 1 << 255; // ActionConstants.CONTRACT_BALANCE
    // RouteNotAllowed(reason) codes
    uint8 internal constant ROUTE_NOT_UR = 1; // swapData not for UR, or a wrong UR or 0x address at deployment
    uint8 internal constant ROUTE_SHAPE = 2; // no commands, or inputs.length != commands.length
    uint8 internal constant ROUTE_COMMAND = 3; // UR command not allowed
    uint8 internal constant ROUTE_RECIPIENT = 4; // swap or sweep recipient is not this contract
    uint8 internal constant ROUTE_PAYER = 5; // payerIsUser = true (a Permit2 pull)
    uint8 internal constant ROUTE_PATH = 6; // path length is not 20 + 23k (k >= 1)
    uint8 internal constant ROUTE_ENDPOINTS = 7; // first or last path token is not tokenIn or tokenOut
    uint8 internal constant ROUTE_TOKEN = 8; // hop token outside the pair's tokens and WETH/USDG, or a == b
    uint8 internal constant ROUTE_FEE = 9; // non-canonical fee tier (not 100/500/3000/10000)
    uint8 internal constant ROUTE_POOL = 10; // no pool in the factory
    uint8 internal constant ROUTE_SWEEP = 11; // sweep token is not tokenIn or tokenOut
    // no tokenIn left in UR: the explicit amounts of the swap commands must add up to EXACTLY amountIn (or one command
    // spends CONTRACT_BALANCE and the explicit amounts do not exceed amountIn)
    uint8 internal constant ROUTE_LEFTOVER = 12;
    // the LAST swap command of an AutoExit route must be CONTRACT_BALANCE: AutoExit's swapAmount is computed on chain
    // from the state at execution, so an explicit amount could go stale between the keeper's read and the execution (a
    // dust poke or an in-range swap), and the exact-sum rule would then make the stop-loss revert
    uint8 internal constant ROUTE_BALANCE_LAST = 13;
    // a swap command AFTER a CONTRACT_BALANCE command (no tokens are left in UR, so UR would revert)
    uint8 internal constant ROUTE_AFTER_BALANCE = 14;
    // minHopPriceX36 is not empty (UR 2.1.1 accepts only an empty one unconditionally; the floor is enforced on chain)
    uint8 internal constant ROUTE_HOP_PRICE = 15;
    // the route does not end with SWEEP(tokenIn): on a partial fill the unspent input would stay in UR, where anyone
    // can sweep it; the last command must sweep tokenIn back to this contract (or MSG_SENDER), and every SWEEP comes
    // after all swap commands (an earlier SWEEP(tokenIn) would take the input out of UR and the next swap would fail)
    uint8 internal constant ROUTE_SWEEP_LAST = 16;
    // a swap command of size 0: an explicit amount of 0, or CONTRACT_BALANCE after the explicit amounts have used up
    // amountIn (the pool would revert with amountSpecified = 0, UniswapV3Pool "AS")
    uint8 internal constant ROUTE_EMPTY_LEG = 17;

    // ---- floor headroom and shallow-pool pre-check ----
    // floor: (1 - floor) = (1 - fee_own)(1 - h)(1 - s). On v3, h = 0: v3 has no PoolManager protocol fee (feeProtocol
    // is taken from the LP fee, so a swapper never pays more than the tier), and a headroom like v4's would only widen
    // the allowed slippage. The constant keeps _floorX64 in the same shape as on v4.
    uint24 public constant FLOOR_HEADROOM_PIPS = 0; // 0 bps (units of 1e6)
    // depth / size: each hop's input may not exceed the amount that moves the hop pool by 100 ticks with its current
    // in-range liquidity (no tick crossing); a constant, independent of the pair's gate
    uint24 public constant MAX_HOP_IMPACT_TICKS = 100;

    // ---- "only the needed swap": unit liquidity (used only for ratios; rounding is negligible)
    uint128 internal constant GP19_UNIT_L = 1e18;
    // ---- lower bound: the keeper swaps slightly less than the need, so the tolerance is 1%. If the need is below
    //      0.1% of the sold token's balance (dust) there is no lower bound (a mint without a swap is accepted) ----
    uint256 internal constant NEED_TOL_BPS = 100;
    uint256 internal constant NEED_DUST_DIV = 1000;

    // exactly the same ABI as Swapper.UniversalRouterData (to decode the data exactly as Swapper does)
    struct GoatURData {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }

    // summary accumulated along the route. (pool, direction) pairs accumulate in a fixed array of 8; more than that
    // reverts with an array-bounds Panic (fail closed; a normal route uses at most 8 distinct (pool, direction) pairs)
    struct GoatRouteAcc {
        uint256 explicitIn; // sum of the explicit amounts of the swap commands (saturating)
        bool usesBalance; // a swap command uses CONTRACT_BALANCE: all tokenIn in UR is spent
        bool lastBalance; // the LAST swap command is CONTRACT_BALANCE
        bool sawSweep; // a SWEEP was seen (no swap command may follow)
        address tokenIn; // this swap's tokens (the pair's two tokens)
        address tokenOut;
        uint256 n; // number of (pool, direction) entries used
        address[8] pools;
        bool[8] dirs;
        uint256[8] sizes; // accumulated input per (pool, direction)
    }

    // input of the need band (one struct to fit the stack)
    struct GoatNeed {
        bool zeroForOne; // the operator's direction
        uint256 amountIn; // the operator's effective swap amount (0 without swapData)
        uint256 a0; // token0 taken out of the position
        uint256 a1; // token1 taken out of the position
        int24 tl; // new range centred on the anchor
        int24 tu;
        int24 anchorTick;
        uint160 anchorSqrtPriceX96;
        uint16 gate; // the pair's G
        uint64 floorX64; // the swap floor
    }

    // ---- Goat errors ----
    error WrongChain();
    error FeeMismatch();
    // route checks
    error RouteNotAllowed(uint8 reason);
    // shallow-pool pre-check
    error ThinPool(address pool, uint256 amountIn, uint256 depth);
    // no swap while one is needed, or a swap below the (tolerant) lower bound of the need
    error SwapAmountTooSmall();
    // the source's 60 s or 10 s TWAP (or its observe) is outside G of the anchor; the source's spot is outside G
    error VetoTwapFar();
    error VetoSpotFar();
    // the code at the address to bind is not the pinned GoatPairTable code
    error PairTableCodeMismatch();

    // binds the table once (onlyOwner and nonReentrant are on the caller, AutoRange or AutoExit); the table must use
    // the same chain constants
    function _setPairTable(GoatPairTable t) internal {
        if (address(pairTable) != address(0)) revert InvalidConfig();
        if (address(t).code.length == 0 || t.WETH() != WETH || t.USDG() != USDG || t.V3_FACTORY() != V3_FACTORY) {
            revert WrongChain();
        }
        // only a table whose founding is sealed (seeding is over; afterwards only timelocked paths)
        if (!t.foundingSealed()) revert InvalidConfig();
        // duck typing is not enough: only GoatPairTable code compiled from the reviewed source
        if (_codeHashNoMetadata(address(t)) != PAIR_TABLE_CODE_HASH) revert PairTableCodeMismatch();
        pairTable = t;
        emit PairTableSet(address(t));
    }

    // keccak256(code[0 : n - 2 - m]), with m = the CBOR metadata length in the last 2 bytes (big-endian). The cut tail
    // is never executed (solc code does not jump into it or copy its own code), so the same prefix byte for byte means
    // the same behaviour. A malformed tail (m + 2 > n) gives 0, which matches no pinned value.
    function _codeHashNoMetadata(address a) internal view returns (bytes32 h) {
        bytes memory c = a.code;
        uint256 n = c.length;
        if (n < 2) return bytes32(0);
        uint256 m = (uint256(uint8(c[n - 2])) << 8) | uint256(uint8(c[n - 1]));
        if (m + 2 > n) return bytes32(0);
        uint256 len = n - m - 2;
        assembly ("memory-safe") {
            h := keccak256(add(c, 32), len)
        }
    }

    // pair and fee coverage, sequencer and both feeds from the table; any problem reverts (fail closed, no fallback).
    // Returns the anchor tick and sqrtPriceX96 (token1/token0 in raw units), the pair's gate G and its veto pool
    // (always set).
    function _getAnchor(address token0, address token1, uint24 fee)
        internal
        view
        returns (int24 tick, uint160 sqrtPriceX96, uint16 gate, IUniswapV3Pool vetoPool)
    {
        GoatPairTable t = pairTable;
        if (address(t) == address(0)) revert InvalidPool();
        address v;
        (tick, sqrtPriceX96, gate, v) = t.anchor(token0, token1, fee);
        // AutoRange and exits with a swap run ONLY on pairs with a veto pool (the table's row check also requires one;
        // this line fails closed should the bound table ever return none)
        if (v == address(0)) revert InvalidPool();
        vetoPool = IUniswapV3Pool(v);
    }

    // source short-TWAP gate and source spot gate. One observe([60, 10, 0]) (a failure or a length other than 3 reverts
    // with VetoTwapFar, fail closed); |TWAP60 - A| <= G and |TWAP10 - A| <= G (means rounded toward negative infinity,
    // inclusive), otherwise VetoTwapFar; |spot(source) - A| <= G, otherwise VetoSpotFar. The source is the row's veto
    // pool (CL) or its reference (NC). The 900 s K check stays in Revert's _validateSwap (on NC rows the anchor is that
    // TWAP900 itself).
    function _checkSourceGate(IUniswapV3Pool src, int24 anchorTick, uint16 gate) internal view {
        uint32[] memory ago = new uint32[](3);
        ago[0] = GATE_TWAP_SLOW;
        ago[1] = GATE_TWAP_FAST;
        try src.observe(ago) returns (int56[] memory c, uint160[] memory) {
            if (c.length != 3) revert VetoTwapFar();
            if (_outsideGate(_meanTick(c[2] - c[0], GATE_TWAP_SLOW), anchorTick, gate)) revert VetoTwapFar();
            if (_outsideGate(_meanTick(c[2] - c[1], GATE_TWAP_FAST), anchorTick, gate)) revert VetoTwapFar();
        } catch {
            revert VetoTwapFar();
        }
        (, int24 s,,,,,) = src.slot0();
        if (_outsideGate(s, anchorTick, gate)) revert VetoSpotFar();
    }

    // window mean of a tickCumulative difference (rounded toward negative infinity, the same rule as
    // Automator._getTWAPTick)
    function _meanTick(int56 d, uint32 window) internal pure returns (int256 t) {
        int56 w = int56(uint56(window));
        t = d / w;
        if (d < 0 && d % w != 0) t--;
    }

    // |x - A| > G (G is an inclusive bound)
    function _outsideGate(int256 x, int24 anchorTick, uint16 gate) internal pure returns (bool) {
        int256 dx = x - int256(anchorTick);
        return (dx < 0 ? -dx : dx) > int256(uint256(gate));
    }

    // charges a swap flow's input to the pair's budget (BEFORE the swap; a CL row is unlimited, so the table returns
    // without a write). Going over reverts with SwapBudgetExceeded (the keeper queues the position for later), a closed
    // pair with SwapsOff. The input counts in its own leg's budget, in its own raw units (the anchor price plays no
    // part in the accounting, so it is not an argument).
    function _consumeSwap(address token0, address token1, bool zeroForOne, uint256 amountIn) internal {
        pairTable.consumeSwap(token0, token1, zeroForOne, amountIn);
    }

    // |spot - anchor| <= G, inclusive (G is the pair's gate from the table)
    function _checkAnchorGate(int24 spotTick, int24 anchorTick, uint16 gate) internal pure {
        int256 d = int256(spotTick) - int256(anchorTick);
        if (d > int256(uint256(gate)) || -d > int256(uint256(gate))) {
            revert PriceDifferenceExceeded();
        }
    }

    // at config time: the pair is listed and the fee tier covered (feed freshness is not required)
    // both legs (AutoRange charges BOTH budgets on every move)
    function _requireAnchoredPair(address token0, address token1, uint24 fee) internal view {
        _requireAnchoredPair(token0, token1, fee, true, true);
    }

    // config-time gate for the legs execution will charge: in0 = the zeroForOne leg (token0 input), in1 = the
    // oneForZero leg. Each pair has two budgets (hard leg in swapBudget, X in swapBudgetX; consumeSwap:
    // hard = zeroForOne == capIn0). A closed (0) budget reverts in consumeSwap with SwapsOff even for a zero input, so
    // a config that would charge that leg is not accepted. For AutoExit: token0Swap -> in0, token1Swap -> in1.
    function _requireAnchoredPair(address token0, address token1, uint24 fee, bool in0, bool in1) internal view {
        GoatPairTable t = pairTable;
        if (address(t) == address(0)) revert InvalidPool();
        (bool listed, bool feeCovered) = t.coverage(token0, token1, fee);
        if (!listed) revert InvalidPool();
        if (!feeCovered) revert NotSupportedFeeTier();
        // a pair with swaps closed (budget 0, set by the guardian or owner with lowerSwapCap) takes no new config with
        // swaps
        (uint128 cap,,) = t.swapBudget(token0, token1);
        (uint128 capX,,) = t.swapBudgetX(token0, token1);
        if (in0 && in1) {
            if (cap == 0 || capX == 0) revert GoatPairTable.SwapsOff();
        } else if (in0 || in1) {
            // one leg: which budget? (on a CL row both budgets are equal; on an NC row capIn0 selects the hard leg)
            bool hard = in0 == t.nc(token0, token1).capIn0;
            if ((hard ? cap : capX) == 0) revert GoatPairTable.SwapsOff();
        }
    }

    // constructor only: chain, WETH, veto pool (factory lookup, independent of PoolAddress) and decimals (feed decimals
    // are checked by the table's row validation)
    function _checkRobinhoodDeployment(address weth_, address vetoPool_) internal view {
        if (block.chainid != 4663 || weth_ != WETH || vetoPool_ != address(VETO_POOL)) revert WrongChain();
        if (IERC20Metadata(WETH).decimals() != 18 || IERC20Metadata(USDG).decimals() != 6) revert InvalidToken();
    }

    // veto TWAP parameter bounds (constructor): TWAPSeconds in [900, 1080], maxTWAPTickDifference == 150. K must be
    // exactly 150 because setTWAPConfig is disabled and K can never change: K = 0 or K < G would block every swap path
    // of AutoRange and AutoExit until a new deployment.
    function _checkVetoConfig(uint32 twapSeconds, uint16 maxTickDifference) internal pure {
        if (
            twapSeconds < VETO_TWAP_SECONDS_MIN || twapSeconds > VETO_TWAP_SECONDS_MAX
                || maxTickDifference != VETO_MAX_TICK_DIFFERENCE
        ) {
            revert InvalidConfig();
        }
    }

    // slippage cap (configToken)
    function _checkSlippageCap(uint64 s0, uint64 s1) internal pure {
        if (s0 > MAX_SLIPPAGE_X64 || s1 > MAX_SLIPPAGE_X64) revert InvalidConfig();
    }

    // fee-net slippage: (1 - net) = (1 - fee_own)(1 - s); fee_own = the position's own pool fee (fee / 1e6)
    function _feeNetX64(uint64 s, uint24 fee) internal pure returns (uint64) {
        return uint64(Q64 - (Q64 - s) * (1_000_000 - fee) / 1_000_000);
    }

    // floor: (1 - floor) = (1 - fee_own)(1 - h)(1 - s): the fee-net value plus the headroom h (h = 0 on v3)
    function _floorX64(uint64 s, uint24 fee) internal pure returns (uint64) {
        return uint64(Q64 - (Q64 - _feeNetX64(s, fee)) * (1_000_000 - FLOOR_HEADROOM_PIPS) / 1_000_000);
    }

    // fee* = min(fee_route, fee_own). fee_route = the size-weighted mean of the combined path fees (1 - prod(1 - f_i))
    // of the route's swap commands, rounded up. Sizes follow _checkV3SwapInput: explicit -> min(amount, amountIn),
    // CONTRACT_BALANCE -> amountIn minus the earlier explicit amounts. A mean rather than a max, so a small expensive
    // leg added to a cheap route cannot raise it. No swapData, not UR, or amountIn = 0 -> fee_own. The route is checked
    // by _checkRoute in the same transaction (a malformed route reverts there). Used for the AutoRange swap floor
    // passed to _validateSwap (the need band keeps fee_own, to match the keeper's model) and for the AutoExit swap
    // floor: _floorX64(s, _phiStar(fee, swapData, input)).
    function _phiStar(uint24 ownFee, bytes memory swapData, uint256 amountIn) internal pure returns (uint24) {
        if (amountIn == 0 || swapData.length < 32) return ownFee;
        uint256 first;
        assembly ("memory-safe") {
            first := mload(add(swapData, 32))
        }
        if (first != uint256(uint160(UNIVERSAL_ROUTER))) return ownFee;
        (, bytes memory routerData) = abi.decode(swapData, (address, bytes));
        GoatURData memory d = abi.decode(routerData, (GoatURData));
        uint256 explicitIn;
        uint256 total;
        uint256 feeSum;
        for (uint256 i; i < d.commands.length && i < d.inputs.length; ++i) {
            if (d.commands[i] != UR_V3_SWAP_EXACT_IN) continue;
            (uint256 size, uint256 fee, uint256 cmdIn) = _phiLeg(d.inputs[i], amountIn, explicitIn);
            if (fee >= 1_000_000) return ownFee; // non-canonical tier: _checkHop rejects it with ROUTE_FEE
            if (cmdIn != UR_CONTRACT_BALANCE) {
                explicitIn = cmdIn > type(uint256).max - explicitIn ? type(uint256).max : explicitIn + cmdIn;
            }
            total += size;
            feeSum += size * fee;
        }
        if (total == 0) return ownFee;
        uint256 phiRoute = (feeSum + total - 1) / total;
        return phiRoute < ownFee ? uint24(phiRoute) : ownFee;
    }

    // size of one swap command (the _checkV3SwapInput rule) and its combined path fee (pips, 1 - prod(1 - f_i), rounded
    // up); a non-canonical tier gives 1e6 (the caller then falls back to fee_own)
    function _phiLeg(bytes memory input, uint256 amountIn, uint256 explicitIn)
        private
        pure
        returns (uint256 size, uint256 fee, uint256 cmdIn)
    {
        bytes memory path;
        (, cmdIn,, path,,) = abi.decode(input, (address, uint256, uint256, bytes, bool, uint256[]));
        size = cmdIn == UR_CONTRACT_BALANCE
            ? (amountIn > explicitIn ? amountIn - explicitIn : 0)
            : (cmdIn > amountIn ? amountIn : cmdIn);
        uint256 keep = 1_000_000;
        for (uint256 off; off + 20 < path.length; off += 23) {
            uint24 f = _pathFee(path, off + 20);
            if (f >= 1_000_000) return (size, 1_000_000, cmdIn);
            keep = keep * (1_000_000 - f) / 1_000_000;
        }
        fee = 1_000_000 - keep;
    }

    // every anchored swap goes through Revert's _validateSwap with the pair's veto pool (there is no floor path without
    // a veto)

    // constructor only: UR equals the fixed address, 0x AllowanceHolder disabled (address(0)), factory
    function _checkSwapVenue(address factory_, address universalRouter_, address zeroxAllowanceHolder_) internal pure {
        if (factory_ != V3_FACTORY) revert WrongChain();
        if (universalRouter_ != UNIVERSAL_ROUTER || zeroxAllowanceHolder_ != address(0)) {
            revert RouteNotAllowed(ROUTE_NOT_UR);
        }
    }

    // the operator's swapData is checked before it reaches Swapper._routerSwap. It is decoded exactly as Swapper
    // decodes it: abi.decode(swapData, (address, bytes)) -> abi.decode(routerData, (UniversalRouterData)); UR is called
    // with these (commands, inputs) only. tokenIn/tokenOut: this swap's tokens (the anchored pair); amountIn: the
    // amount the contract transfers to UR; anchorSqrtPriceX96: the token1/token0 anchor price (only to estimate hop
    // sizes); balanceLast: the last swap command must be CONTRACT_BALANCE (AutoExit; false in AutoRange, where amountIn
    // is the keeper's).
    function _checkRoute(
        bytes memory swapData,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint160 anchorSqrtPriceX96,
        bool balanceLast
    ) internal view {
        // the 0x path is disabled: the same check as Swapper's (first word == UR)
        uint256 first;
        if (swapData.length >= 32) {
            assembly {
                first := mload(add(swapData, 32))
            }
        }
        if (first != uint256(uint160(UNIVERSAL_ROUTER))) revert RouteNotAllowed(ROUTE_NOT_UR);
        (, bytes memory routerData) = abi.decode(swapData, (address, bytes));
        GoatURData memory d = abi.decode(routerData, (GoatURData));
        uint256 n = d.commands.length;
        if (n == 0 || d.inputs.length != n) revert RouteNotAllowed(ROUTE_SHAPE);
        // route summary (leftover, accumulated depth, the pair's tokens)
        GoatRouteAcc memory acc;
        acc.tokenIn = tokenIn;
        acc.tokenOut = tokenOut;
        for (uint256 i; i < n; ++i) {
            bytes1 c = d.commands[i];
            if (c == UR_V3_SWAP_EXACT_IN) {
                _checkV3SwapInput(d.inputs[i], amountIn, anchorSqrtPriceX96, acc);
            } else if (c == UR_SWEEP) {
                (address token, address recipient,) = abi.decode(d.inputs[i], (address, address, uint256));
                if (token != tokenIn && token != tokenOut) revert RouteNotAllowed(ROUTE_SWEEP);
                if (recipient != address(this) && recipient != UR_MSG_SENDER) revert RouteNotAllowed(ROUTE_RECIPIENT);
                acc.sawSweep = true; // no swap command may follow
            } else {
                revert RouteNotAllowed(ROUTE_COMMAND);
            }
        }
        // the contract transfers all of amountIn to UR (Swapper): the explicit amounts must add up to EXACTLY amountIn
        // (a shortfall would stay in UR, where anyone can sweep it; an excess reverts at run time), or one command
        // spends the whole rest with CONTRACT_BALANCE (then the explicit amounts may not exceed amountIn)
        if (acc.usesBalance ? acc.explicitIn > amountIn : acc.explicitIn != amountIn) {
            revert RouteNotAllowed(ROUTE_LEFTOVER);
        }
        // AutoExit: the last swap command spends the whole rest (CONTRACT_BALANCE), so drift or a poke cannot make the
        // route stale
        if (balanceLast && !acc.lastBalance) revert RouteNotAllowed(ROUTE_BALANCE_LAST);
        // the last command is SWEEP(tokenIn) (its recipient was checked in the loop: this contract or MSG_SENDER): on a
        // partial fill (range edge, liquidity exhausted) unspent tokenIn does not stay in UR but returns to the
        // contract
        if (d.commands[n - 1] != UR_SWEEP) revert RouteNotAllowed(ROUTE_SWEEP_LAST);
        (address lastSweep,,) = abi.decode(d.inputs[n - 1], (address, address, uint256));
        if (lastSweep != tokenIn) revert RouteNotAllowed(ROUTE_SWEEP_LAST);
    }

    // UR 2.1.1 V3_SWAP_EXACT_IN input, 6 fields:
    // (recipient, amountIn, amountOutMin, path, payerIsUser, minHopPriceX36)
    function _checkV3SwapInput(bytes memory input, uint256 amountIn, uint160 anchorSqrtPriceX96, GoatRouteAcc memory acc)
        private
        view
    {
        // CONTRACT_BALANCE spends all tokenIn in UR; any later swap command (explicit or a second CONTRACT_BALANCE)
        // would find no tokens and UR would revert, so the check rejects it too
        if (acc.usesBalance) revert RouteNotAllowed(ROUTE_AFTER_BALANCE);
        // no swap after a SWEEP (an earlier SWEEP(tokenIn) empties UR)
        if (acc.sawSweep) revert RouteNotAllowed(ROUTE_SWEEP_LAST);
        (uint256 cmdIn, bytes memory path) = _decodeV3SwapInput(input);
        uint256 len = path.length;
        if (len < 43 || (len - 20) % 23 != 0) revert RouteNotAllowed(ROUTE_PATH);
        if (_pathToken(path, 0) != acc.tokenIn || _pathToken(path, len - 20) != acc.tokenOut) {
            revert RouteNotAllowed(ROUTE_ENDPOINTS);
        }
        // hop size: the command's amount (capped at the amount the contract transfers); hops in tokenOut terms are
        // converted at the anchor price. A CONTRACT_BALANCE command spends what is LEFT in UR: amountIn minus the
        // earlier explicit amounts (a later explicit command would find no tokens; a donation to UR only raises the
        // input, the output goes to the contract and the floor comes from swapAmount). So the last leg of a split
        // AutoExit route [explicit X, CONTRACT_BALANCE] is measured at its real size.
        uint256 size = cmdIn == UR_CONTRACT_BALANCE
            ? (amountIn > acc.explicitIn ? amountIn - acc.explicitIn : 0)
            : (cmdIn > amountIn ? amountIn : cmdIn);
        // an empty leg would revert in UR (pool error "AS"), so the check rejects it too
        if (size == 0) revert RouteNotAllowed(ROUTE_EMPTY_LEG);
        // route summary: raw explicit amounts are summed with saturation (for the exact-sum rule; no overflow)
        if (cmdIn == UR_CONTRACT_BALANCE) acc.usesBalance = true;
        else acc.explicitIn = cmdIn > type(uint256).max - acc.explicitIn ? type(uint256).max : acc.explicitIn + cmdIn;
        acc.lastBalance = cmdIn == UR_CONTRACT_BALANCE; // the last swap command so far
        _checkHops(path, size, _convertAtAnchor(size, acc.tokenIn < acc.tokenOut, anchorSqrtPriceX96), acc);
    }

    // recipient is this contract (or MSG_SENDER), payerIsUser = false; returns the command's amountIn and path
    function _decodeV3SwapInput(bytes memory input) private view returns (uint256 cmdIn, bytes memory path) {
        address recipient;
        bool payerIsUser;
        uint256[] memory minHopPriceX36;
        (recipient, cmdIn,, path, payerIsUser, minHopPriceX36) =
            abi.decode(input, (address, uint256, uint256, bytes, bool, uint256[]));
        if (recipient != address(this) && recipient != UR_MSG_SENDER) revert RouteNotAllowed(ROUTE_RECIPIENT);
        if (payerIsUser) revert RouteNotAllowed(ROUTE_PAYER);
        // per-hop minimum prices are not used (a length mismatch or a high value reverts in UR; the protection is the
        // floor and the gates on chain)
        if (minHopPriceX36.length != 0) revert RouteNotAllowed(ROUTE_HOP_PRICE);
    }

    // every hop (a, fee, b): a and b allowed tokens, a != b, canonical tier, pool in the factory, depth (the body is in
    // _checkHop so that the summary `acc` fits the stack)
    function _checkHops(bytes memory path, uint256 size, uint256 sizeOut, GoatRouteAcc memory acc) private view {
        uint256 len = path.length;
        for (uint256 off; off + 20 < len; off += 23) {
            _checkHop(path, off, size, sizeOut, acc);
        }
    }

    function _checkHop(bytes memory path, uint256 off, uint256 size, uint256 sizeOut, GoatRouteAcc memory acc)
        private
        view
    {
        address a = _pathToken(path, off);
        uint24 fee = _pathFee(path, off + 20);
        address b = _pathToken(path, off + 23);
        if (!_isRouteToken(a, acc) || !_isRouteToken(b, acc) || a == b) revert RouteNotAllowed(ROUTE_TOKEN);
        if (fee != 100 && fee != 500 && fee != 3000 && fee != 10000) revert RouteNotAllowed(ROUTE_FEE);
        address pool = IUniswapV3Factory(V3_FACTORY).getPool(a, b, fee);
        if (pool == address(0)) revert RouteNotAllowed(ROUTE_POOL);
        // depth is measured with the input ACCUMULATED along the route for the same (pool, direction), so splitting
        // across commands or repeating a hop does not get around it. The input of an intermediate token (WETH or USDG,
        // outside the pair) is estimated at the table's anchor prices (not at spot, which can be moved).
        uint256 hopIn = a == acc.tokenIn ? size : a == acc.tokenOut ? sizeOut : _quoteHop(acc, a, size);
        _checkDepth(pool, a < b, _accumulate(acc, pool, a < b, hopIn));
    }

    // the value of `size` (in tokenIn) in the intermediate token `a` (the table's feeds; reverts on any problem)
    function _quoteHop(GoatRouteAcc memory acc, address a, uint256 size) private view returns (uint256) {
        (address t0, address t1) = acc.tokenIn < acc.tokenOut ? (acc.tokenIn, acc.tokenOut) : (acc.tokenOut, acc.tokenIn);
        return pairTable.quote(t0, t1, acc.tokenIn, a, size);
    }

    // (pool, direction) accumulation; returns that entry's total input along the route (saturating sum)
    function _accumulate(GoatRouteAcc memory acc, address pool, bool zeroForOne, uint256 amt)
        private
        pure
        returns (uint256)
    {
        uint256 k;
        while (k < acc.n && (acc.pools[k] != pool || acc.dirs[k] != zeroForOne)) ++k;
        if (k == acc.n) {
            acc.pools[k] = pool;
            acc.dirs[k] = zeroForOne;
            acc.n = k + 1;
        }
        uint256 cur = acc.sizes[k];
        acc.sizes[k] = amt > type(uint256).max - cur ? type(uint256).max : cur + amt;
        return acc.sizes[k];
    }

    // hop token set = this swap's two tokens (the pair) + WETH + USDG
    function _isRouteToken(address t, GoatRouteAcc memory acc) internal pure returns (bool) {
        return t == acc.tokenIn || t == acc.tokenOut || t == WETH || t == USDG;
    }

    // shallow-pool pre-check: the input may not exceed the amount that moves the pool by MAX_HOP_IMPACT_TICKS with its
    // current in-range liquidity. Tick crossings are ignored (best effort); the hard limits are the floor and the
    // gates.
    function _checkDepth(address pool, bool zeroForOne, uint256 amountIn) internal view {
        (uint160 sqrtP, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        uint128 L = IUniswapV3Pool(pool).liquidity();
        int24 t = zeroForOne ? tick - int24(MAX_HOP_IMPACT_TICKS) : tick + int24(MAX_HOP_IMPACT_TICKS);
        if (t < TickMath.MIN_TICK) t = TickMath.MIN_TICK;
        if (t > TickMath.MAX_TICK) t = TickMath.MAX_TICK;
        uint160 sqrtT = TickMath.getSqrtRatioAtTick(t);
        uint256 depth;
        if (zeroForOne) {
            if (sqrtT < sqrtP) depth = FullMath.mulDiv(uint256(L) << 96, sqrtP - sqrtT, sqrtP) / sqrtT;
        } else {
            if (sqrtT > sqrtP) depth = FullMath.mulDiv(L, sqrtT - sqrtP, Q96);
        }
        if (amountIn > depth) revert ThinPool(pool, amountIn, depth);
    }

    // token0 -> token1 (zeroForOne) or the reverse, at the anchor price (size estimate only)
    function _convertAtAnchor(uint256 amount, bool zeroForOne, uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (priceX96 == 0) return type(uint256).max;
        return zeroForOne ? FullMath.mulDiv(amount, priceX96, Q96) : FullMath.mulDiv(amount, Q96, priceX96);
    }

    function _pathToken(bytes memory path, uint256 off) private pure returns (address a) {
        assembly {
            a := shr(96, mload(add(add(path, 32), off)))
        }
    }

    function _pathFee(bytes memory path, uint256 off) private pure returns (uint24 f) {
        assembly {
            f := shr(232, mload(add(add(path, 32), off)))
        }
    }

    // "only the needed swap": the operator's DIRECTION and AMOUNT must lie in the need band computed on chain. The
    // keeper mints at the spot price AFTER the swap; that spot is inside the gate band (anchor +- G) and the swap price
    // lies between the floor and the band's top. The need is monotonic in the mint price and the swap price:
    //   upper bound: the band's worst end and the floor price, so every valid amount is <= the upper bound; above it
    //     reverts with SwapAmountTooLarge
    //   lower bound: the band's other end and the best price (the band's edge), so every valid amount is >= the lower
    //     bound; with a 1% tolerance, below it (or no swap while one is needed) reverts with SwapAmountTooSmall
    // In the direction that is not needed the upper bound is 0 (this enforces the direction). A dust need (<= 0.1% of
    // the sold balance) gives no lower bound.
    function _checkSwapNeed(GoatNeed memory q) internal pure {
        if (q.amountIn > _maxSwapIn(q)) revert SwapAmountTooLarge();
        uint256 lo0 = _minSwapInTol(true, q);
        uint256 lo1 = _minSwapInTol(false, q);
        if (q.amountIn == 0 ? (lo0 != 0 || lo1 != 0) : q.amountIn < (q.zeroForOne ? lo0 : lo1)) {
            revert SwapAmountTooSmall();
        }
    }

    // upper bound. (x_u, y_u) = the amounts of unit liquidity at the band's end; P = anchor price (token1/token0).
    //   selling token0: x <= (A0 * y_u - A1 * x_u) / (y_u + x_u * P * (1 - floor)),   end = anchor + G + 1
    //   selling token1: y <= (A1 * x_u - A0 * y_u) / (x_u + y_u * (1 - floor) / P),   end = anchor - G
    // If the numerator is negative (no swap is needed in that direction) the bound is 0. If the range is fully crossed
    // at the end, the bound is the whole balance.
    function _maxSwapIn(GoatNeed memory q) internal pure returns (uint256) {
        // the token0 end is the TOP of the band: the gate accepts spot tick <= A + G, that is sqrtP < P(A + G + 1) (the
        // same end as in _minSwapInTol)
        int24 t = q.zeroForOne ? q.anchorTick + int24(uint24(q.gate)) + 1 : q.anchorTick - int24(uint24(q.gate));
        (uint256 xu, uint256 yu) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(t), TickMath.getSqrtRatioAtTick(q.tl), TickMath.getSqrtRatioAtTick(q.tu), GP19_UNIT_L
        );
        uint256 pX96 = FullMath.mulDiv(q.anchorSqrtPriceX96, q.anchorSqrtPriceX96, Q96); // token1/token0, Q96
        uint256 keepX64 = Q64 - q.floorX64; // (1 - floor)
        if (q.zeroForOne) {
            uint256 have = FullMath.mulDiv(q.a0, yu, 1);
            uint256 other = FullMath.mulDiv(q.a1, xu, 1);
            if (have <= other) return 0;
            return (have - other) / (yu + FullMath.mulDiv(FullMath.mulDiv(xu, pX96, Q96), keepX64, Q64)) + 1;
        } else {
            uint256 have = FullMath.mulDiv(q.a1, xu, 1);
            uint256 other = FullMath.mulDiv(q.a0, yu, 1);
            if (have <= other) return 0;
            return (have - other) / (xu + FullMath.mulDiv(FullMath.mulDiv(yu, Q96, pX96), keepX64, Q64)) + 1;
        }
    }

    // lower bound (with tolerance). The band's other end (selling token0: anchor - G; selling token1: anchor + G + 1)
    // and the best price (selling token0: P(anchor + G + 1); selling token1: P(anchor - G)):
    //   selling token0: x >= (A0 * y_u - A1 * x_u) / (y_u + x_u * P_top)
    //   selling token1: y >= (A1 * x_u - A0 * y_u) / (x_u + y_u / P_bottom)
    // Returns (1 - 1%) * need; 0 if the need is <= 0.1% of the sold balance (dust).
    function _minSwapInTol(bool zeroForOne, GoatNeed memory q) internal pure returns (uint256 lo) {
        int24 g = int24(uint24(q.gate));
        int24 tEdge = zeroForOne ? q.anchorTick - g : q.anchorTick + g + 1;
        (uint256 xu, uint256 yu) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtRatioAtTick(tEdge),
            TickMath.getSqrtRatioAtTick(q.tl),
            TickMath.getSqrtRatioAtTick(q.tu),
            GP19_UNIT_L
        );
        uint160 sp = TickMath.getSqrtRatioAtTick(zeroForOne ? q.anchorTick + g + 1 : q.anchorTick - g);
        uint256 pX96 = FullMath.mulDiv(sp, sp, Q96); // token1/token0, Q96
        uint256 need;
        if (zeroForOne) {
            uint256 have = FullMath.mulDiv(q.a0, yu, 1);
            uint256 other = FullMath.mulDiv(q.a1, xu, 1);
            if (have <= other) return 0;
            need = (have - other) / (yu + FullMath.mulDiv(xu, pX96, Q96));
            if (need * NEED_DUST_DIV <= q.a0) return 0;
        } else {
            uint256 have = FullMath.mulDiv(q.a1, xu, 1);
            uint256 other = FullMath.mulDiv(q.a0, yu, 1);
            if (have <= other) return 0;
            need = (have - other) / (xu + FullMath.mulDiv(yu, Q96, pX96));
            if (need * NEED_DUST_DIV <= q.a1) return 0;
        }
        lo = need - need * NEED_TOL_BPS / 10_000;
    }

    // the new range is centred on the anchor: Revert's floor-rounding expression shifted by +ts/2, which rounds to the
    // nearest multiple of the tick spacing (ties round up). The width (ud - ld) is kept exactly.
    function _rangeFromAnchor(int24 anchor, int32 ld, int32 ud, int24 ts) internal pure returns (int32 lo, int32 hi) {
        int32 t = int32(anchor) + ld + int32(ts / 2);
        lo = t - (((t % ts) + ts) % ts);
        hi = lo + (ud - ld);
    }
}

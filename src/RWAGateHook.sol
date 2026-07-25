// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Works for both ERC-20 and ERC-721 (ComplianceNFT) balance reads.
interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface IDecimals {
    function decimals() external view returns (uint8);
}

/// @title RWAGateHook — Uniswap v4 hook: compliance gate + TWAP oracle
/// @notice The secondary-market lane of RWA Outlets (docs/03-contracts.md §2.6).
///         `beforeSwap` / `beforeAddLiquidity` require the initiating user (from hookData,
///         falling back to tx.origin) to hold the ComplianceNFT. `afterSwap` maintains a
///         v2-style cumulative price accumulator whose `twapRate` is the OutletRouter's sanity
///         bound over program quotes.
/// @dev This file compiles in the v4 unit (solc 0.8.26); the router reads it through the
///      pragma-neutral `IRwaTwapSource` interface.
contract RWAGateHook is IHooks {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- types

    struct Observation {
        uint40 timestamp;
        uint256 cumulativeX128; // Σ priceX128 × elapsed, price = token1-per-token0 raw
    }

    struct OracleState {
        uint160 lastSqrtPriceX96;
        uint40 lastTimestamp;
        uint256 cumulativeX128;
        address currency0;
        address currency1;
        Observation[] observations; // demo-scale; production would use a ring buffer
    }

    // ---------------------------------------------------------------- state

    IPoolManager public immutable POOL_MANAGER;
    IBalanceOf public immutable COMPLIANCE;
    address public immutable USDC;

    mapping(PoolId => OracleState) private _oracle;

    // ---------------------------------------------------------------- events

    /// @param rate1e18 Spot USDC-per-RWA rate, decimals-normalized (0 when neither side is
    ///        USDC — the hook is built for RWA/USDC pools; see `_toUsdcPerRwa1e18`). Gives the
    ///        subgraph a ready-made secondary-market price series with no offchain Q64.96 math.
    event ObservationRecorded(
        PoolId indexed poolId, uint160 sqrtPriceX96, uint256 rate1e18, uint256 cumulativeX128
    );

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error NotCompliant(address user);
    error HookNotImplemented();
    error NoObservations(PoolId poolId);
    error WindowNotCovered(PoolId poolId, uint32 window);
    error NotAUsdcPool(PoolId poolId);

    modifier onlyPoolManager() {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager poolManager, IBalanceOf compliance, address usdc) {
        POOL_MANAGER = poolManager;
        COMPLIANCE = compliance;
        USDC = usdc;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    // ------------------------------------------------------------ gated hooks

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata hookData)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireCompliant(hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external view onlyPoolManager returns (bytes4) {
        _requireCompliant(hookData);
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();
        OracleState storage s = _oracle[id];
        uint40 ts = uint40(block.timestamp);

        if (s.currency0 == address(0)) {
            s.currency0 = Currency.unwrap(key.currency0);
            s.currency1 = Currency.unwrap(key.currency1);
        }
        if (s.lastTimestamp != 0 && ts > s.lastTimestamp) {
            s.cumulativeX128 += _priceX128(s.lastSqrtPriceX96) * (ts - s.lastTimestamp);
        }

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        s.lastSqrtPriceX96 = sqrtPriceX96;

        uint256 count = s.observations.length;
        if (count > 0 && s.observations[count - 1].timestamp == ts) {
            s.observations[count - 1].cumulativeX128 = s.cumulativeX128;
        } else {
            s.observations.push(Observation(ts, s.cumulativeX128));
        }
        s.lastTimestamp = ts;

        // normalized only for USDC pools so afterSwap can never revert on exotic pairs
        uint256 rate1e18 = (s.currency0 == USDC || s.currency1 == USDC)
            ? _toUsdcPerRwa1e18(s, _priceX128(sqrtPriceX96))
            : 0;
        emit ObservationRecorded(id, sqrtPriceX96, rate1e18, s.cumulativeX128);
        return (IHooks.afterSwap.selector, 0);
    }

    // -------------------------------------------------------------- TWAP view

    /// @notice Time-weighted USDC-per-RWA rate (1e18, decimals-normalized) over `window`
    ///         seconds. Matches `IRwaTwapSource.twapRate` (PoolId is a bytes32 user type).
    function twapRate(bytes32 rawPoolId, uint32 window) external view returns (uint256 rate1e18) {
        PoolId id = PoolId.wrap(rawPoolId);
        OracleState storage s = _oracle[id];
        uint256 count = s.observations.length;
        if (count == 0) revert NoObservations(id);

        uint256 nowTs = block.timestamp;
        uint256 cumNow = s.cumulativeX128
            + _priceX128(s.lastSqrtPriceX96) * (nowTs - s.lastTimestamp);
        uint256 target = nowTs - window;

        // newest observation at or before the window start (bounded demo history)
        for (uint256 i = count; i > 0; i--) {
            Observation storage o = s.observations[i - 1];
            if (o.timestamp <= target) {
                uint256 avgX128 = (cumNow - o.cumulativeX128) / (nowTs - o.timestamp);
                return _toUsdcPerRwa1e18(s, avgX128);
            }
        }
        revert WindowNotCovered(id, window);
    }

    function observationCount(bytes32 rawPoolId) external view returns (uint256) {
        return _oracle[PoolId.wrap(rawPoolId)].observations.length;
    }

    /// @notice Spot USDC-per-RWA rate (1e18) from the last recorded price.
    function lastRate(bytes32 rawPoolId) external view returns (uint256) {
        OracleState storage s = _oracle[PoolId.wrap(rawPoolId)];
        if (s.lastTimestamp == 0) revert NoObservations(PoolId.wrap(rawPoolId));
        return _toUsdcPerRwa1e18(s, _priceX128(s.lastSqrtPriceX96));
    }

    // ------------------------------------------------------------- internals

    function _requireCompliant(bytes calldata hookData) private view {
        address user = hookData.length >= 20 ? address(bytes20(hookData[:20])) : tx.origin;
        if (COMPLIANCE.balanceOf(user) == 0) revert NotCompliant(user);
    }

    /// @dev token1-per-token0 raw price in Q128: (sqrtP/2^96)^2 × 2^128.
    function _priceX128(uint160 sqrtPriceX96) private pure returns (uint256) {
        return FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 64);
    }

    /// @dev Normalizes a raw Q128 token1-per-token0 price into USDC-per-RWA at 1e18.
    function _toUsdcPerRwa1e18(OracleState storage s, uint256 priceX128)
        private
        view
        returns (uint256)
    {
        uint8 d0 = IDecimals(s.currency0).decimals();
        uint8 d1 = IDecimals(s.currency1).decimals();
        if (s.currency1 == USDC) {
            // RWA is currency0: rate = raw × 10^(18 + d0 − d1)
            return FullMath.mulDiv(priceX128, 10 ** (18 + d0 - d1), 1 << 128);
        } else if (s.currency0 == USDC) {
            // RWA is currency1: invert
            return FullMath.mulDiv(10 ** (18 + d1 - d0), 1 << 128, priceX128);
        }
        revert NotAUsdcPool(PoolId.wrap(bytes32(0)));
    }

    // --------------------------------------------- unused callbacks (unflagged)

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}

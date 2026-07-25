// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {IV4Venue} from "./interfaces/IV4Venue.sol";

/// @title V4Venue — Uniswap v4 execution leg of the OutletRouter
/// @notice The secondary-market fallback venue (docs/02-engine-spec.md §6): the router
///         compares its best Aqua/SwapVM program quote against the RWA/USDC v4 pool and
///         executes here when v4 is better. One venue serves every listed asset; pools are
///         registered per asset by the owner and are expected to carry the RWAGateHook —
///         the initiating user is forwarded as hookData so the hook's compliance gate and
///         TWAP observations see the real user, not this contract.
/// @dev Compiles in the v4 unit (solc 0.8.26); the 0.8.30 router talks to it through the
///      pragma-neutral `IV4Venue` interface, mirroring the `IRwaTwapSource` pattern.
///      Holds no funds: input is pulled from the caller only inside the swap and settled to
///      the PoolManager in the same transaction; output is taken straight to the recipient.
contract V4Venue is IV4Venue, IUnlockCallback, Ownable {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    // ---------------------------------------------------------------- types

    struct SwapData {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        address recipient;
        bytes hookData;
    }

    // ---------------------------------------------------------------- state

    IPoolManager public immutable POOL_MANAGER;
    IV4Quoter public immutable QUOTER;
    address public immutable USDC;

    mapping(address asset => PoolKey) private _keyOf;
    mapping(address asset => bytes32) public poolIdOf;

    // ---------------------------------------------------------------- events

    event PoolRegistered(
        address indexed asset, bytes32 indexed poolId, uint24 fee, int24 tickSpacing, address hooks
    );
    event V4Swapped(
        address indexed asset,
        address indexed user,
        address indexed recipient,
        bool assetForUsdc,
        uint256 amountIn,
        uint256 amountOut
    );

    // ---------------------------------------------------------------- errors

    error NotPoolManager();
    error PoolNotRegistered(address asset);
    error PoolNotInitialized(bytes32 poolId);
    error AmountOverflow(uint256 amountIn);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);

    constructor(IPoolManager poolManager, IV4Quoter quoter, address usdc) Ownable(msg.sender) {
        POOL_MANAGER = poolManager;
        QUOTER = quoter;
        USDC = usdc;
    }

    // ------------------------------------------------------------ registration

    /// @notice Registers the asset's RWA/USDC pool. The pool must already be initialized on
    ///         the PoolManager; currencies are derived as the sorted (asset, USDC) pair.
    function registerPool(address asset, uint24 fee, int24 tickSpacing, address hooks)
        external
        onlyOwner
        returns (bytes32 rawPoolId)
    {
        (Currency c0, Currency c1) = asset < USDC
            ? (Currency.wrap(asset), Currency.wrap(USDC))
            : (Currency.wrap(USDC), Currency.wrap(asset));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });

        PoolId id = key.toId();
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(id);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized(PoolId.unwrap(id));

        _keyOf[asset] = key;
        poolIdOf[asset] = PoolId.unwrap(id);
        emit PoolRegistered(asset, PoolId.unwrap(id), fee, tickSpacing, hooks);
        return PoolId.unwrap(id);
    }

    // ---------------------------------------------------------------- quoting

    /// @inheritdoc IV4Venue
    function quoteExactIn(address asset, bool assetForUsdc, uint256 amountIn, address user)
        external
        returns (uint256 amountOut)
    {
        (PoolKey memory key, bool zeroForOne) = _direction(asset, assetForUsdc);
        if (amountIn > type(uint128).max) revert AmountOverflow(amountIn);

        (amountOut,) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(amountIn),
                hookData: abi.encodePacked(user)
            })
        );
    }

    // --------------------------------------------------------------- swapping

    function swapExactIn(
        address asset,
        bool assetForUsdc,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        address user
    ) external returns (uint256 amountOut) {
        (PoolKey memory key, bool zeroForOne) = _direction(asset, assetForUsdc);
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountOverflow(amountIn);

        address tokenIn = assetForUsdc ? asset : USDC;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        bytes memory result = POOL_MANAGER.unlock(
            abi.encode(
                SwapData({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountIn: amountIn,
                    recipient: recipient,
                    hookData: abi.encodePacked(user)
                })
            )
        );
        amountOut = abi.decode(result, (uint256));
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);

        emit V4Swapped(asset, user, recipient, assetForUsdc, amountIn, amountOut);
    }

    /// @dev PoolManager callback: swap, settle the input (sync → transfer → settle), take the
    ///      output straight to the recipient. Deltas net to zero by construction.
    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        SwapData memory d = abi.decode(rawData, (SwapData));

        BalanceDelta delta = POOL_MANAGER.swap(
            d.key,
            SwapParams({
                zeroForOne: d.zeroForOne,
                amountSpecified: -int256(d.amountIn), // exact input
                sqrtPriceLimitX96: d.zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            d.hookData
        );

        (Currency currencyIn, Currency currencyOut, int128 outSigned) = d.zeroForOne
            ? (d.key.currency0, d.key.currency1, delta.amount1())
            : (d.key.currency1, d.key.currency0, delta.amount0());
        uint256 amountOut = uint256(uint128(outSigned));

        currencyIn.settle(POOL_MANAGER, address(this), d.amountIn, false);
        currencyOut.take(POOL_MANAGER, d.recipient, amountOut, false);

        return abi.encode(amountOut);
    }

    // -------------------------------------------------------------- internals

    function _direction(address asset, bool assetForUsdc)
        private
        view
        returns (PoolKey memory key, bool zeroForOne)
    {
        if (poolIdOf[asset] == bytes32(0)) revert PoolNotRegistered(asset);
        key = _keyOf[asset];
        address tokenIn = assetForUsdc ? asset : USDC;
        zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
    }
}

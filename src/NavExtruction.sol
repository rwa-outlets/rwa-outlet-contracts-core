// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {SwapQuery, SwapRegisters} from "swap-vm/src/libs/VM.sol";

import {NavOracle} from "./NavOracle.sol";

/// @title NavExtruction — NAV-anchored pricing for SwapVM programs (docs/03-contracts.md §2.3)
/// @notice Implements the official `IExtruction`/`IStaticExtruction` duals as ONE function
///         (identical selector): pure pricing, no state writes, and no events in static mode so
///         `quote()` works under staticcall. Deterministic per block — required for quote/swap
///         consistency; the official Extruction instruction forbids backward jumps to it.
///
/// Three pool modes, selected by the first args byte:
///  - FixedSpread (Pool 1 Express): amounts at NAV × (1 ∓ spread), both trade directions.
///  - DutchDecay  (Pool 2 Patient): exit-only; discount decays linearly from startBps to
///    floorBps over [startTime, startTime + duration]; expired auctions revert.
///  - NavBand     (Pool 3 Market):  post-check on amounts already set by `_xycSwapXD`;
///    reverts if the implied rate leaves NAV ± band.
///
/// Program args layout (packed, after the 20-byte extruction target):
///   [0] mode | [1] poolId | [2:22] asset | [22:42] quote | mode params:
///   FixedSpread: [42:44] spreadBps u16 | [44:48] maxStaleness u32
///   DutchDecay:  [42:44] startBps u16 | [44:46] floorBps u16 | [46:51] startTime u40
///                | [51:55] duration u32 | [55:59] maxStaleness u32
///   NavBand:     [42:44] bandBps u16 | [44:48] maxStaleness u32
contract NavExtruction {
    enum Mode {
        FixedSpread,
        DutchDecay,
        NavBand
    }

    uint256 private constant BPS = 10_000;

    NavOracle public immutable NAV_ORACLE;

    /// @notice Emitted on swap execution only (never during static quoting).
    /// @param strategyHash The order/strategy hash (Aqua strategyHash for shipped pools)
    /// @param rateVsNavBps Signed execution premium (+) or discount (−) vs oracle NAV, in bps
    event Trade(
        bytes32 indexed strategyHash,
        uint8 indexed poolId,
        address indexed asset,
        bool isExit,
        address maker,
        address taker,
        uint256 amountIn,
        uint256 amountOut,
        int256 rateVsNavBps
    );

    error BadArgs();
    error TokenPairMismatch(address tokenIn, address tokenOut);
    error NavStale(address asset, uint256 updatedAt, uint256 maxStaleness);
    error RecomputeDetected();
    error DecayExitOnly();
    error DecayMisconfigured(uint16 startBps, uint16 floorBps);
    error AuctionExpired(uint256 startTime, uint256 duration);
    error SpreadTooLarge(uint256 bps);
    error BandRequiresComputedAmounts();
    error RateOutsideNavBand(uint256 implied1e18, uint256 nav1e18, uint16 bandBps);

    constructor(NavOracle oracle) {
        NAV_ORACLE = oracle;
    }

    /// @notice Official SwapVM extruction entrypoint (both static and swap contexts).
    /// @dev Called by the router's `_extruction` instruction via call (swap) or staticcall
    ///      (quote). Returns `nextPC` unchanged and `choppedLength = 0`.
    function extruction(
        bool isStaticContext,
        uint256 nextPC,
        SwapQuery calldata query,
        SwapRegisters calldata swap,
        bytes calldata args,
        bytes calldata /* takerData */
    ) external returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap) {
        updatedSwap = swap;

        if (args.length < 42) revert BadArgs();
        Mode mode = Mode(uint8(args[0]));
        uint8 poolId = uint8(args[1]);
        address asset = address(bytes20(args[2:22]));
        address quote = address(bytes20(args[22:42]));

        bool isExit;
        if (query.tokenIn == asset && query.tokenOut == quote) {
            isExit = true;
        } else if (query.tokenIn == quote && query.tokenOut == asset) {
            isExit = false;
        } else {
            revert TokenPairMismatch(query.tokenIn, query.tokenOut);
        }

        // shares (assetDecimals) × rate (1e18) / scale → quote units
        uint256 scale =
            10 ** (18 + IERC20Metadata(asset).decimals() - IERC20Metadata(quote).decimals());

        uint256 nav;
        uint256 implied1e18;

        if (mode == Mode.FixedSpread) {
            if (args.length != 48) revert BadArgs();
            uint16 spreadBps = uint16(bytes2(args[42:44]));
            if (spreadBps >= BPS) revert SpreadTooLarge(spreadBps);
            nav = _freshNav(asset, uint32(bytes4(args[44:48])));

            uint256 rate = isExit
                ? (nav * (BPS - spreadBps)) / BPS // maker buys RWA below NAV
                : (nav * (BPS + spreadBps)) / BPS; // maker sells RWA above NAV
            implied1e18 = _applyRate(updatedSwap, query.isExactIn, isExit, rate, scale);
        } else if (mode == Mode.DutchDecay) {
            if (args.length != 59) revert BadArgs();
            if (!isExit) revert DecayExitOnly();
            uint16 startBps = uint16(bytes2(args[42:44]));
            uint16 floorBps = uint16(bytes2(args[44:46]));
            uint256 startTime = uint40(bytes5(args[46:51]));
            uint256 duration = uint32(bytes4(args[51:55]));
            if (floorBps < startBps || floorBps >= BPS || duration == 0) {
                revert DecayMisconfigured(startBps, floorBps);
            }
            nav = _freshNav(asset, uint32(bytes4(args[55:59])));

            if (block.timestamp >= startTime + duration) revert AuctionExpired(startTime, duration);
            uint256 elapsed = block.timestamp <= startTime ? 0 : block.timestamp - startTime;
            // discount deepens linearly from startBps toward floorBps as the auction ages
            uint256 discountBps = startBps + ((floorBps - startBps) * elapsed) / duration;

            uint256 rate = (nav * (BPS - discountBps)) / BPS;
            implied1e18 = _applyRate(updatedSwap, query.isExactIn, isExit, rate, scale);
        } else {
            // NavBand: post-check over amounts computed earlier in the program (e.g. _xycSwapXD)
            if (args.length != 48) revert BadArgs();
            uint16 bandBps = uint16(bytes2(args[42:44]));
            nav = _freshNav(asset, uint32(bytes4(args[44:48])));

            if (updatedSwap.amountIn == 0 || updatedSwap.amountOut == 0) {
                revert BandRequiresComputedAmounts();
            }
            implied1e18 = isExit
                ? Math.mulDiv(updatedSwap.amountOut, scale, updatedSwap.amountIn)
                : Math.mulDiv(updatedSwap.amountIn, scale, updatedSwap.amountOut);
            if (
                implied1e18 < (nav * (BPS - bandBps)) / BPS
                    || implied1e18 > (nav * (BPS + bandBps)) / BPS
            ) {
                revert RateOutsideNavBand(implied1e18, nav, bandBps);
            }
        }

        if (!isStaticContext && updatedSwap.amountIn > 0 && updatedSwap.amountOut > 0) {
            emit Trade(
                query.orderHash,
                poolId,
                asset,
                isExit,
                query.maker,
                query.taker,
                updatedSwap.amountIn,
                updatedSwap.amountOut,
                // rates are bounded by spread/band params, nowhere near int256 overflow
                // forge-lint: disable-next-line(unsafe-typecast)
                int256((implied1e18 * BPS) / nav) - int256(BPS)
            );
        }

        return (nextPC, 0, updatedSwap);
    }

    /// @dev Computes the missing register at `rate` (quote-per-asset, 1e18), rounding in the
    ///      maker's favor: outputs floor, inputs ceil. Returns the implied 1e18 rate.
    function _applyRate(
        SwapRegisters memory regs,
        bool isExactIn,
        bool isExit,
        uint256 rate,
        uint256 scale
    ) private pure returns (uint256 implied1e18) {
        if (isExactIn) {
            if (regs.amountOut != 0) revert RecomputeDetected();
            regs.amountOut = isExit
                ? Math.mulDiv(regs.amountIn, rate, scale) // asset in → quote out
                : Math.mulDiv(regs.amountIn, scale, rate); // quote in → asset out
        } else {
            if (regs.amountIn != 0) revert RecomputeDetected();
            regs.amountIn = isExit
                ? Math.mulDiv(regs.amountOut, scale, rate, Math.Rounding.Ceil)
                : Math.mulDiv(regs.amountOut, rate, scale, Math.Rounding.Ceil);
        }
        if (regs.amountIn == 0 || regs.amountOut == 0) return rate;
        implied1e18 = isExit
            ? Math.mulDiv(regs.amountOut, scale, regs.amountIn)
            : Math.mulDiv(regs.amountIn, scale, regs.amountOut);
    }

    function _freshNav(address asset, uint32 maxStaleness) private view returns (uint256 nav) {
        (uint256 nav1e18, uint40 updatedAt) = NAV_ORACLE.navOf(asset);
        if (block.timestamp - updatedAt > maxStaleness) {
            revert NavStale(asset, updatedAt, maxStaleness);
        }
        return nav1e18;
    }
}

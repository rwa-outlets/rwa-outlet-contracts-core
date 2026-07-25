// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {RWAGateHook, IBalanceOf} from "../src/RWAGateHook.sol";
import {ComplianceNFT} from "../src/ComplianceNFT.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {RWAToken} from "../src/RWAToken.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice RWAGateHook against the REAL v4 PoolManager: compliance gating on swap/liquidity
///         and the cumulative-price TWAP the OutletRouter uses as its sanity band.
contract RWAGateHookTest is Test {
    uint256 internal constant NAV = 1.0432e18;

    PoolManager internal manager;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    ComplianceNFT internal kyc;
    TestUSDC internal usdc;
    RWAToken internal rwa;
    RWAGateHook internal hook;

    PoolKey internal key;
    bytes32 internal poolId;

    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        manager = new PoolManager(address(this));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        kyc = new ComplianceNFT();
        usdc = new TestUSDC();
        rwa = new RWAToken("Tokenized Private Credit", "rwaCREDIT", IERC721(address(kyc)));

        // hook address must encode its permission bits (beforeAddLiquidity|beforeSwap|afterSwap)
        address hookAddr = address(
            uint160(0x1000) << 144
                | uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
        );
        deployCodeTo(
            "RWAGateHook.sol:RWAGateHook",
            abi.encode(manager, IBalanceOf(address(kyc)), address(usdc)),
            hookAddr
        );
        hook = RWAGateHook(hookAddr);

        (Currency c0, Currency c1) = address(usdc) < address(rwa)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(rwa)))
            : (Currency.wrap(address(rwa)), Currency.wrap(address(usdc)));
        key = PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(hookAddr)});
        poolId = PoolId.unwrap(key.toId());

        manager.initialize(key, _sqrtPriceForNav());

        // this contract provides liquidity and takes swaps
        usdc.mint(address(this), 100_000_000e6);
        rwa.mint(address(this), 1e27); // full-range liquidity at ~1e-12 raw price is token0-heavy
        usdc.approve(address(swapRouter), type(uint256).max);
        rwa.approve(address(swapRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);
        rwa.approve(address(lpRouter), type(uint256).max);

        kyc.mint(user);
    }

    /// @dev sqrtPriceX96 matching USDC-per-RWA = NAV for whichever token ordering applies.
    function _sqrtPriceForNav() internal view returns (uint160) {
        // raw token1-per-token0 price: rate × 10^(d1 − d0), as a 2^192-scaled square
        uint256 rawX192;
        if (Currency.unwrap(key.currency1) == address(usdc)) {
            // RWA is token0: raw = NAV × 10^(6-18) / 1e18
            rawX192 = Math.mulDiv(NAV, 1 << 192, 1e30);
        } else {
            // USDC is token0: raw = (1/NAV) × 10^(18-6) / 1e-... → 1e30 / NAV
            rawX192 = Math.mulDiv(1e30, 1 << 192, NAV) / 1e18;
        }
        return uint160(Math.sqrt(rawX192));
    }

    function _addLiquidity(address as_) internal {
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 5e18, salt: 0}),
            abi.encodePacked(as_)
        );
    }

    function _swap(address as_, bool zeroForOne, int256 amountSpecified) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encodePacked(as_)
        );
    }

    /// @dev exact-in swap sized in the pool's token0 or token1 respectively.
    function _smallSwapAmount(bool zeroForOne) internal view returns (int256) {
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        return tokenIn == address(usdc) ? -int256(1_000e6) : -int256(1_000e18);
    }

    // ------------------------------------------------------------ compliance

    function test_LiquidityGate() public {
        vm.expectRevert(); // NotCompliant(stranger) wrapped by the manager
        _addLiquidity(stranger);

        _addLiquidity(user); // KYC'd — passes
    }

    function test_SwapGate() public {
        _addLiquidity(user);

        vm.expectRevert();
        _swap(stranger, true, _smallSwapAmount(true));

        _swap(user, true, _smallSwapAmount(true)); // KYC'd — passes
        assertEq(hook.observationCount(poolId), 1, "afterSwap recorded");
    }

    // ------------------------------------------------------------------ twap

    function test_LastRateMatchesInitPrice() public {
        _addLiquidity(user);
        _swap(user, true, _smallSwapAmount(true));

        // pool seeded at NAV; tiny swap moves price a little
        assertApproxEqRel(hook.lastRate(poolId), NAV, 0.02e18, "spot within 2% of NAV");
    }

    /// @dev The subgraph consumes `rate1e18` straight from the event — it must match the
    ///      `lastRate()` view and sit at the pool price.
    function test_ObservationRecorded_carriesNormalizedRate() public {
        _addLiquidity(user);

        vm.recordLogs();
        _swap(user, true, _smallSwapAmount(true));

        bytes32 sig = keccak256("ObservationRecorded(bytes32,uint160,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            assertEq(logs[i].topics[1], poolId, "poolId topic");
            (, uint256 rate1e18,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(rate1e18, hook.lastRate(poolId), "event rate == lastRate()");
            assertApproxEqRel(rate1e18, NAV, 0.02e18, "rate near NAV");
            found = true;
        }
        assertTrue(found, "ObservationRecorded emitted");
    }

    function test_TwapOverWindow() public {
        _addLiquidity(user);

        // absolute warps: via-IR legally caches the TIMESTAMP opcode within a function, so
        // `block.timestamp + n` after a prior warp would reuse the pre-warp value
        uint256 t0 = block.timestamp;
        _swap(user, true, _smallSwapAmount(true));
        vm.warp(t0 + 600);
        _swap(user, false, _smallSwapAmount(false));
        vm.warp(t0 + 1200);

        uint256 twap = hook.twapRate(poolId, 900);
        assertApproxEqRel(twap, NAV, 0.05e18, "TWAP anchored near NAV");
        assertEq(hook.observationCount(poolId), 2);
    }

    function test_TwapWindowNotCoveredReverts() public {
        _addLiquidity(user);
        _swap(user, true, _smallSwapAmount(true));

        // only one observation, just now — a 1-hour window has no anchor point
        vm.expectRevert();
        hook.twapRate(poolId, 3600);
    }

    function test_NoObservationsReverts() public {
        vm.expectRevert();
        hook.lastRate(poolId);
        vm.expectRevert();
        hook.twapRate(poolId, 60);
    }

    function test_OnlyPoolManagerCallsHooks() public {
        vm.expectRevert(RWAGateHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: 0}),
            toBalanceDelta(0, 0),
            ""
        );
    }
}

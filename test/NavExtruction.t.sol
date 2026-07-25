// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {SwapQuery, SwapRegisters} from "swap-vm/src/libs/VM.sol";

import {OutletTestBase} from "./base/OutletTestBase.sol";
import {OutletPrograms} from "../src/libraries/OutletPrograms.sol";
import {NavExtruction} from "../src/NavExtruction.sol";

/// @notice NavExtruction executed through the OFFICIAL Aqua + AquaSwapVMRouter — quote/swap
///         consistency, both directions, exactIn/exactOut, staleness, gating, decay, band.
contract NavExtructionTest is OutletTestBase {
    uint16 internal constant SPREAD_BPS = 20;
    uint32 internal constant STALENESS = 1 days;

    ISwapVM.Order internal expressOrder;
    bytes32 internal expressHash;

    function setUp() public override {
        super.setUp();
        expressOrder = buildOrder(
            maker,
            OutletPrograms.expressProgram(
                address(navX), 1, address(rwa), address(usdc), SPREAD_BPS, STALENESS, address(0), 1
            )
        );
        // Express pool: 1M USDC of exit liquidity, RWA side starts empty
        expressHash = ship(expressOrder, 1_000_000e6, 0);
    }

    // ------------------------------------------------------------ helpers

    /// @dev NAV × (1 − spread) exit rate, mirroring the contract's fixed-point math.
    function exitRate() internal pure returns (uint256) {
        return (NAV * (10_000 - SPREAD_BPS)) / 10_000;
    }

    function entryRate() internal pure returns (uint256) {
        return (NAV * (10_000 + SPREAD_BPS)) / 10_000;
    }

    // ---------------------------------------------------------- express pool

    function test_ExpressExit_ExactIn() public {
        uint256 amountIn = 100e18;
        rwa.mint(address(this), amountIn);

        (uint256 qIn, uint256 qOut) = quote(expressOrder, address(rwa), address(usdc), amountIn, true);
        uint256 expected = (amountIn * exitRate()) / RWA_SCALE; // 104.11136e6 exactly
        assertEq(qIn, amountIn, "quote amountIn");
        assertEq(qOut, expected, "quote amountOut at NAV - spread");
        assertEq(qOut, 104_111_360, "known-value check");

        (uint256 sIn, uint256 sOut) = swap(expressOrder, address(rwa), address(usdc), amountIn, true);
        assertEq(sIn, qIn, "quote == swap amountIn");
        assertEq(sOut, qOut, "quote == swap amountOut");
        assertEq(usdc.balanceOf(address(this)), expected, "taker received USDC");

        // Aqua virtual balances moved: USDC down, RWA up (capital reuse!)
        (uint256 usdcBal, uint256 rwaBal) = aquaBalances(expressHash, maker);
        assertEq(usdcBal, 1_000_000e6 - expected, "shipped USDC decremented");
        assertEq(rwaBal, amountIn, "RWA pushed into strategy");
        // and the RWA physically sits in the maker's wallet (Aqua = allowances)
        assertEq(rwa.balanceOf(maker), 10_000_000e18 + amountIn, "maker wallet holds RWA");
    }

    function test_ExpressExit_ExactOut_RoundsAgainstTaker() public {
        uint256 wantOut = 50_000e6;
        (uint256 qIn, uint256 qOut) = quote(expressOrder, address(rwa), address(usdc), wantOut, false);
        assertEq(qOut, wantOut, "exact out honored");
        // ceil rounding: re-deriving output from the quoted input can't underpay the maker
        assertGe((qIn * exitRate()) / RWA_SCALE, wantOut, "maker-favored rounding");

        rwa.mint(address(this), qIn);
        (uint256 sIn, uint256 sOut) = swap(expressOrder, address(rwa), address(usdc), wantOut, false);
        assertEq(sIn, qIn, "quote == swap exactOut");
        assertEq(sOut, wantOut);
    }

    function test_ExpressEntry_ExactIn() public {
        // maker sells RWA above NAV; ship RWA-side inventory first
        ISwapVM.Order memory buyOrder = buildOrder(
            maker,
            OutletPrograms.expressProgram(
                address(navX), 1, address(rwa), address(usdc), SPREAD_BPS, STALENESS, address(0), 2
            )
        );
        ship(buyOrder, 0, 1_000e18);

        uint256 usdcIn = 104_528_640; // 104.52864e6 → exactly 100e18 RWA at NAV × 1.002
        usdc.mint(address(this), usdcIn);

        (, uint256 qOut) = quote(buyOrder, address(usdc), address(rwa), usdcIn, true);
        assertEq(qOut, (usdcIn * RWA_SCALE) / entryRate(), "entry priced at NAV + spread");
        assertEq(qOut, 100e18, "known-value entry");

        (, uint256 sOut) = swap(buyOrder, address(usdc), address(rwa), usdcIn, true);
        assertEq(sOut, qOut, "quote == swap");
        assertEq(rwa.balanceOf(address(this)), 100e18, "taker received RWA");
    }

    function test_StaleNavReverts() public {
        vm.warp(block.timestamp + STALENESS + 1);
        rwa.mint(address(this), 1e18);
        vm.expectRevert(); // NavStale bubbles through the router
        swap(expressOrder, address(rwa), address(usdc), 1e18, true);

        // refresh NAV → works again
        oracle.setNav(address(rwa), NAV);
        (, uint256 out) = swap(expressOrder, address(rwa), address(usdc), 1e18, true);
        assertGt(out, 0, "fresh NAV re-enables pool");
    }

    function test_ThresholdProtectsTaker() public {
        rwa.mint(address(this), 100e18);
        uint256 tooMuch = 105e6 * 100; // demands more than NAV - spread pays
        vm.expectRevert();
        swapVM.swap(
            expressOrder, address(rwa), address(usdc), 100e18, takerData(true, tooMuch)
        );
    }

    function test_InventoryBoundsFill() public {
        // over-ask beyond shipped inventory → Aqua pull reverts (partial fills = smaller asks)
        uint256 hugeExit = 2_000_000e18; // needs ~2.08M USDC > 1M shipped
        rwa.mint(address(this), hugeExit);
        vm.expectRevert();
        swap(expressOrder, address(rwa), address(usdc), hugeExit, true);

        // a smaller ask still fills
        (, uint256 out) = swap(expressOrder, address(rwa), address(usdc), 100e18, true);
        assertGt(out, 0);
    }

    // --------------------------------------------------------- gated pools

    function test_ComplianceGateViaStockOpcode() public {
        ISwapVM.Order memory gated = buildOrder(
            maker,
            OutletPrograms.expressProgram(
                address(navX), 1, address(rwa), address(usdc), SPREAD_BPS, STALENESS, address(kyc), 3
            )
        );
        ship(gated, 100_000e6, 0);
        rwa.mint(address(this), 10e18);

        address user = makeAddr("user");
        // tx.origin without a pass → the stock _onlyTxOriginTokenBalanceNonZero opcode reverts
        vm.prank(address(this), user);
        vm.expectRevert();
        swapVM.swap(gated, address(rwa), address(usdc), 10e18, takerData(true, 0));

        kyc.mint(user);
        vm.prank(address(this), user);
        (, uint256 out,) = swapVM.swap(gated, address(rwa), address(usdc), 10e18, takerData(true, 0));
        assertGt(out, 0, "KYC'd origin passes");
    }

    // --------------------------------------------------------- patient pool

    function test_PatientDecay_DiscountDeepensOverTime() public {
        uint40 start = uint40(block.timestamp);
        uint32 duration = 3 days;
        ISwapVM.Order memory patient = buildOrder(
            maker,
            OutletPrograms.patientProgram(
                address(navX), 2, address(rwa), address(usdc), 30, 300, start, duration, STALENESS, address(0), 4
            )
        );
        ship(patient, 1_000_000e6, 0);

        // t = 0: discount = startBps (30)
        (, uint256 outStart) = quote(patient, address(rwa), address(usdc), 100e18, true);
        assertEq(outStart, (100e18 * ((NAV * (10_000 - 30)) / 10_000)) / RWA_SCALE, "start discount");

        // t = half: discount = 165 bps (linear midpoint); keeper refreshes NAV daily
        vm.warp(start + duration / 2);
        oracle.setNav(address(rwa), NAV);
        (, uint256 outMid) = quote(patient, address(rwa), address(usdc), 100e18, true);
        assertEq(outMid, (100e18 * ((NAV * (10_000 - 165)) / 10_000)) / RWA_SCALE, "midpoint discount");
        assertLt(outMid, outStart, "quote worsens as auction ages");

        // expiry reverts
        vm.warp(start + duration);
        oracle.setNav(address(rwa), NAV);
        rwa.mint(address(this), 100e18);
        vm.expectRevert();
        swap(patient, address(rwa), address(usdc), 100e18, true);
    }

    function test_PatientEntryDirectionReverts() public {
        ISwapVM.Order memory patient = buildOrder(
            maker,
            OutletPrograms.patientProgram(
                address(navX), 2, address(rwa), address(usdc), 30, 300,
                uint40(block.timestamp), 3 days, STALENESS, address(0), 5
            )
        );
        ship(patient, 0, 1_000e18);
        usdc.mint(address(this), 1_000e6);
        vm.expectRevert(); // DecayExitOnly
        swap(patient, address(usdc), address(rwa), 1_000e6, true);
    }

    // ---------------------------------------------------------- market pool

    function test_MarketXycWithinBand() public {
        // two-sided xyc pool balanced at NAV: reserves 500k USDC / ~479k RWA
        uint256 rwaReserve = 479_000e18;
        uint256 usdcReserve = (rwaReserve * NAV) / RWA_SCALE;
        ISwapVM.Order memory market = buildOrder(
            maker,
            OutletPrograms.marketProgram(
                address(navX), 3, address(rwa), address(usdc), 100, STALENESS, address(0), 6
            )
        );
        bytes32 marketHash = ship(market, usdcReserve, rwaReserve);

        // small exit: xyc price ≈ NAV, inside the 100 bps band
        rwa.mint(address(this), 100e18);
        (uint256 qIn, uint256 qOut) = quote(market, address(rwa), address(usdc), 100e18, true);
        (uint256 sIn, uint256 sOut) = swap(market, address(rwa), address(usdc), 100e18, true);
        assertEq(qIn, sIn);
        assertEq(qOut, sOut, "xyc quote == swap");
        uint256 implied = (sOut * RWA_SCALE) / sIn;
        assertApproxEqRel(implied, NAV, 0.01e18, "fill near NAV");

        // entry direction works on the same shipped balances (two-sided!)
        usdc.mint(address(this), 1_000e6);
        (, uint256 rwaOut) = swap(market, address(usdc), address(rwa), 1_000e6, true);
        assertGt(rwaOut, 0, "same strategy serves buys");

        (uint256 usdcBal, uint256 rwaBal) = aquaBalances(marketHash, maker);
        assertGt(usdcBal, 0);
        assertGt(rwaBal, 0);
    }

    function test_MarketBandRejectsDepeggedFill() public {
        // pool seeded 5% away from NAV → NavBand (100 bps) rejects every fill
        uint256 rwaReserve = 479_000e18;
        uint256 usdcReserve = ((rwaReserve * NAV) / RWA_SCALE) * 95 / 100;
        ISwapVM.Order memory market = buildOrder(
            maker,
            OutletPrograms.marketProgram(
                address(navX), 3, address(rwa), address(usdc), 100, STALENESS, address(0), 7
            )
        );
        ship(market, usdcReserve, rwaReserve);

        rwa.mint(address(this), 100e18);
        vm.expectRevert(); // RateOutsideNavBand
        swap(market, address(rwa), address(usdc), 100e18, true);
    }

    // ------------------------------------------------------- direct unit edges

    function test_DirectCall_TokenPairMismatch() public {
        SwapQuery memory q = SwapQuery({
            orderHash: bytes32(0),
            maker: maker,
            taker: address(this),
            tokenIn: address(rwa),
            tokenOut: address(rwa),
            isExactIn: true
        });
        SwapRegisters memory r;
        r.amountIn = 1e18;
        bytes memory args =
            OutletPrograms.fixedSpreadArgs(1, address(rwa), address(usdc), SPREAD_BPS, STALENESS);
        vm.expectRevert(
            abi.encodeWithSelector(
                NavExtruction.TokenPairMismatch.selector, address(rwa), address(rwa)
            )
        );
        navX.extruction(false, 0, q, r, args, "");
    }

    function test_DirectCall_ReturnsUnchangedPCAndZeroChop() public {
        SwapQuery memory q = SwapQuery({
            orderHash: bytes32("x"),
            maker: maker,
            taker: address(this),
            tokenIn: address(rwa),
            tokenOut: address(usdc),
            isExactIn: true
        });
        SwapRegisters memory r;
        r.amountIn = 100e18;
        bytes memory args =
            OutletPrograms.fixedSpreadArgs(1, address(rwa), address(usdc), SPREAD_BPS, STALENESS);
        (uint256 pc, uint256 chopped, SwapRegisters memory updated) =
            navX.extruction(true, 42, q, r, args, "");
        assertEq(pc, 42, "nextPC unchanged");
        assertEq(chopped, 0, "no taker args consumed");
        assertEq(updated.amountOut, (100e18 * exitRate()) / RWA_SCALE);
        assertEq(updated.amountIn, 100e18, "amountIn untouched");
    }

    function test_DirectCall_StaticContextEmitsNoEvent() public {
        SwapQuery memory q = SwapQuery({
            orderHash: bytes32("x"),
            maker: maker,
            taker: address(this),
            tokenIn: address(rwa),
            tokenOut: address(usdc),
            isExactIn: true
        });
        SwapRegisters memory r;
        r.amountIn = 1e18;
        bytes memory args =
            OutletPrograms.fixedSpreadArgs(1, address(rwa), address(usdc), SPREAD_BPS, STALENESS);

        vm.recordLogs();
        navX.extruction(true, 0, q, r, args, "");
        assertEq(vm.getRecordedLogs().length, 0, "static mode is log-free (staticcall-safe)");

        vm.recordLogs();
        navX.extruction(false, 0, q, r, args, "");
        assertEq(vm.getRecordedLogs().length, 1, "swap mode emits Trade");
    }
}

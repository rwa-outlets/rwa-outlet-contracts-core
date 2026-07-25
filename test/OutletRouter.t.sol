// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {OutletTestBase} from "./base/OutletTestBase.sol";
import {OutletPrograms} from "../src/libraries/OutletPrograms.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {IRwaTwapSource} from "../src/interfaces/IRwaTwapSource.sol";

contract MockTwapSource is IRwaTwapSource {
    uint256 public rate;
    bool public hasData;

    function set(uint256 rate_, bool hasData_) external {
        rate = rate_;
        hasData = hasData_;
    }

    function twapRate(bytes32, uint32) external view returns (uint256) {
        require(hasData, "no observations");
        return rate;
    }
}

/// @notice OutletRouter: best-of quoting across pools, execution, TWAP guard, queue forwarding.
contract OutletRouterTest is OutletTestBase {
    OutletRouter internal router;
    MockTwapSource internal twap;
    RedemptionQueue internal queue;

    ISwapVM.Order internal tightPool; // 20 bps spread — should win exits
    ISwapVM.Order internal widePool; // 80 bps spread
    bytes32 internal tightHash;
    bytes32 internal wideHash;

    address internal user = makeAddr("user");
    address internal issuer = makeAddr("issuer");

    function setUp() public override {
        super.setUp();
        router = new OutletRouter(ISwapVM(address(swapVM)), IERC20(address(usdc)), oracle);
        twap = new MockTwapSource();
        queue = new RedemptionQueue(
            IERC20(address(rwa)), IERC20(address(usdc)), address(this), issuer, address(this), 5, 0
        );

        tightPool = buildOrder(
            maker,
            OutletPrograms.expressProgram(
                address(navX), 1, address(rwa), address(usdc), 20, 1 days, address(0), 10
            )
        );
        widePool = buildOrder(
            maker,
            OutletPrograms.expressProgram(
                address(navX), 1, address(rwa), address(usdc), 80, 1 days, address(0), 11
            )
        );
        ship(tightPool, 500_000e6, 500_000e18);
        ship(widePool, 500_000e6, 500_000e18);

        tightHash = router.registerStrategy(address(rwa), tightPool);
        wideHash = router.registerStrategy(address(rwa), widePool);

        rwa.mint(user, 1_000e18);
        usdc.mint(user, 1_000_000e6);
        vm.startPrank(user);
        rwa.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------- quoting

    function test_BestOfQuotingPicksTightestSpread() public view {
        (bytes32 bestHash, uint256 bestOut) = router.quoteInstant(address(rwa), 100e18);
        assertEq(bestHash, tightHash, "20 bps pool wins exits");
        assertEq(bestOut, (100e18 * ((NAV * (10_000 - 20)) / 10_000)) / RWA_SCALE);

        // buys: taker wants cheap RWA — tighter spread also wins (NAV + 20 < NAV + 80)
        (bytes32 buyHash,) = router.quoteBuy(address(rwa), 1_000e6);
        assertEq(buyHash, tightHash, "20 bps pool wins buys");
    }

    function test_QuoteSkipsBrokenListings() public {
        // stale NAV breaks both pools → no executable quote
        vm.warp(block.timestamp + 2 days);
        (bytes32 bestHash, uint256 bestOut) = router.quoteInstant(address(rwa), 100e18);
        assertEq(bestHash, bytes32(0));
        assertEq(bestOut, 0);

        vm.expectRevert(
            abi.encodeWithSelector(OutletRouter.NoExecutableQuote.selector, address(rwa), 100e18)
        );
        vm.prank(user);
        router.redeemInstant(address(rwa), 100e18, 0);
    }

    // ------------------------------------------------------------ execution

    function test_RedeemInstant_EndToEnd() public {
        uint256 amount = 100e18;
        (, uint256 expected) = router.quoteInstant(address(rwa), amount);

        vm.prank(user);
        uint256 out = router.redeemInstant(address(rwa), amount, expected);
        assertEq(out, expected, "quote == execution");
        assertEq(usdc.balanceOf(user), 1_000_000e6 + expected, "USDC straight to user");
        assertEq(rwa.balanceOf(user), 900e18);
        // router is a pure pass-through — no residue
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(rwa.balanceOf(address(router)), 0);
    }

    function test_Buy_EndToEnd() public {
        uint256 usdcIn = 10_000e6;
        (, uint256 expected) = router.quoteBuy(address(rwa), usdcIn);

        vm.prank(user);
        uint256 out = router.buy(address(rwa), usdcIn, expected);
        assertEq(out, expected);
        assertEq(rwa.balanceOf(user), 1_000e18 + expected, "RWA straight to user");
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_MinOutProtects() public {
        (, uint256 expected) = router.quoteInstant(address(rwa), 100e18);
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(OutletRouter.InsufficientOutput.selector, expected, expected + 1)
        );
        router.redeemInstant(address(rwa), 100e18, expected + 1);
    }

    // ------------------------------------------------------------ twap guard

    function test_TwapGuard_BlocksOnlyWhenNavStale() public {
        router.setGuard(address(rwa), twap, bytes32("pool"), 300, 100); // 1% band, 5 min window

        // TWAP 5% off the program quote, but NAV was just pushed → oracle wins, trade passes
        twap.set((NAV * 95) / 100, true);
        oracle.setNav(address(rwa), NAV);
        vm.prank(user);
        uint256 out = router.redeemInstant(address(rwa), 10e18, 0);
        assertGt(out, 0, "fresh NAV overrides TWAP deviation");

        // NAV older than the TWAP window + deviation → guard blocks
        vm.warp(block.timestamp + 301); // NAV now stale for the guard, still fresh for the pool
        vm.prank(user);
        vm.expectRevert(); // QuoteOutsideTwapBand
        router.redeemInstant(address(rwa), 10e18, 0);

        // no TWAP data at all → guard is a no-op
        twap.set(0, false);
        vm.prank(user);
        out = router.redeemInstant(address(rwa), 10e18, 0);
        assertGt(out, 0, "guard inactive without observations");
    }

    // ------------------------------------------------------------- listings

    function test_DelistAuth() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OutletRouter.NotRegistrar.selector, tightHash));
        router.delistStrategy(tightHash);

        router.delistStrategy(tightHash); // we registered it
        (bytes32 bestHash,) = router.quoteInstant(address(rwa), 100e18);
        assertEq(bestHash, wideHash, "wide pool remains");
        assertEq(router.listingsOf(address(rwa)).length, 1);
    }

    function test_DuplicateListingReverts() public {
        vm.expectRevert(abi.encodeWithSelector(OutletRouter.AlreadyListed.selector, tightHash));
        router.registerStrategy(address(rwa), tightPool);
    }

    // ------------------------------------------------------------ queue path

    function test_EnqueueForwardsToQueue() public {
        router.setQueue(address(rwa), queue);

        vm.startPrank(user);
        rwa.approve(address(queue), type(uint256).max); // queue pulls from owner
        queue.setOperator(address(router), true); // router files on user's behalf
        uint256 epoch = router.enqueue(address(rwa), 50e18);
        vm.stopPrank();

        assertEq(epoch, 1);
        assertEq(queue.pendingRedeemRequest(1, user), 50e18, "user is the controller");
        assertEq(rwa.balanceOf(address(queue)), 50e18);
    }

    function test_EnqueueWithoutQueueReverts() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OutletRouter.NoQueueForAsset.selector, address(rwa)));
        router.enqueue(address(rwa), 1e18);
    }
}

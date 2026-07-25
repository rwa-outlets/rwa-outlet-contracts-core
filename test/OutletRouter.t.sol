// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {OutletTestBase} from "./base/OutletTestBase.sol";
import {OutletPrograms} from "../src/libraries/OutletPrograms.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {IRwaTwapSource} from "../src/interfaces/IRwaTwapSource.sol";
import {IV4Venue} from "../src/interfaces/IV4Venue.sol";

/// @dev Stands in for the 0.8.26-unit V4Venue (covered by V4Venue.t.sol against the real
///      PoolManager): fills at a configurable USDC-per-RWA rate from its own balances.
contract MockV4Venue is IV4Venue {
    IERC20 internal immutable RWA;
    IERC20 internal immutable USDC;
    uint256 internal constant RWA_SCALE = 1e30; // 10^(18 + 18 − 6)

    uint256 public rate1e18; // USDC per RWA
    bool public listed;

    constructor(IERC20 rwa_, IERC20 usdc_) {
        RWA = rwa_;
        USDC = usdc_;
    }

    function set(uint256 rate1e18_, bool listed_) external {
        rate1e18 = rate1e18_;
        listed = listed_;
    }

    function poolIdOf(address) external view returns (bytes32) {
        return listed ? bytes32(uint256(0xF00F)) : bytes32(0);
    }

    function quoteExactIn(address, bool assetForUsdc, uint256 amountIn, address)
        public
        view
        returns (uint256)
    {
        return assetForUsdc ? (amountIn * rate1e18) / RWA_SCALE : (amountIn * RWA_SCALE) / rate1e18;
    }

    function swapExactIn(
        address asset,
        bool assetForUsdc,
        uint256 amountIn,
        uint256 minOut,
        address recipient,
        address user
    ) external returns (uint256 out) {
        out = quoteExactIn(asset, assetForUsdc, amountIn, user);
        require(out >= minOut, "minOut");
        (IERC20 tokenIn, IERC20 tokenOut) = assetForUsdc ? (RWA, USDC) : (USDC, RWA);
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        tokenOut.transfer(recipient, out);
    }
}

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

    // ------------------------------------------------------------- v4 venue

    function _wireV4(uint256 rate1e18) internal returns (MockV4Venue v4) {
        v4 = new MockV4Venue(IERC20(address(rwa)), IERC20(address(usdc)));
        usdc.mint(address(v4), 1_000_000e6);
        rwa.mint(address(v4), 1_000_000e18);
        v4.set(rate1e18, true);
        router.setV4Venue(IV4Venue(address(v4)));
    }

    function test_V4WinsExit_whenAquaSpreadWider() public {
        // pools quote NAV − 20 bps; v4 at flat NAV beats them
        MockV4Venue v4 = _wireV4(NAV);
        uint256 amount = 100e18;
        uint256 v4Out = (amount * NAV) / RWA_SCALE;

        (bytes32 bestHash, uint256 bestOut, bool viaV4) =
            router.quoteInstantAll(address(rwa), amount, user);
        assertTrue(viaV4, "v4 wins");
        assertEq(bestHash, v4.poolIdOf(address(rwa)), "bestHash is the v4 poolId");
        assertEq(bestOut, v4Out);

        vm.prank(user);
        uint256 out = router.redeemInstant(address(rwa), amount, v4Out);
        assertEq(out, v4Out, "filled at the v4 rate");
        assertEq(usdc.balanceOf(user), 1_000_000e6 + v4Out, "USDC straight to user");
        assertEq(rwa.balanceOf(address(v4)), 1_000_000e18 + amount, "venue took the RWA");
        assertEq(usdc.balanceOf(address(router)), 0, "no router residue");
        assertEq(rwa.balanceOf(address(router)), 0);
    }

    function test_AquaWinsExit_whenV4Worse() public {
        _wireV4((NAV * 95) / 100); // v4 5% below NAV loses to NAV − 20 bps

        (bytes32 bestHash,, bool viaV4) = router.quoteInstantAll(address(rwa), 100e18, user);
        assertFalse(viaV4, "Aqua wins");
        assertEq(bestHash, tightHash);

        (, uint256 aquaOut) = router.quoteInstant(address(rwa), 100e18);
        vm.prank(user);
        assertEq(router.redeemInstant(address(rwa), 100e18, aquaOut), aquaOut);
    }

    function test_V4WinsBuy_whenAquaAsksMore() public {
        // pools sell RWA at NAV + 20 bps; v4 at flat NAV gives more RWA per USDC
        MockV4Venue v4 = _wireV4(NAV);
        uint256 usdcIn = 10_000e6;
        uint256 v4Out = (usdcIn * RWA_SCALE) / NAV;

        (,, bool viaV4) = router.quoteBuyAll(address(rwa), usdcIn, user);
        assertTrue(viaV4, "v4 wins buys");

        vm.prank(user);
        uint256 out = router.buy(address(rwa), usdcIn, v4Out);
        assertEq(out, v4Out);
        assertEq(rwa.balanceOf(user), 1_000e18 + v4Out, "RWA straight to user");
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_V4Unlisted_orBrokenQuote_isSkipped() public {
        MockV4Venue v4 = _wireV4(NAV);

        // delisted → poolIdOf is zero → skipped before quoting
        v4.set(NAV, false);
        (bytes32 bestHash,, bool viaV4) = router.quoteInstantAll(address(rwa), 100e18, user);
        assertFalse(viaV4);
        assertEq(bestHash, tightHash);

        // listed but broken (rate 0 → division-by-zero revert) → quote caught, Aqua wins
        v4.set(0, true);
        (bestHash,, viaV4) = router.quoteInstantAll(address(rwa), 100e18, user);
        assertFalse(viaV4);
        assertEq(bestHash, tightHash);
    }

    function test_V4Fill_respectsTwapGuard() public {
        MockV4Venue v4 = _wireV4(NAV);
        router.setGuard(address(rwa), twap, bytes32("pool"), 300, 100); // 1% band

        // TWAP 5% away, NAV stale for the guard window → even the v4 fill is blocked
        // (absolute warps: via-IR caches TIMESTAMP within a function, see RWAGateHook.t.sol)
        uint256 t0 = block.timestamp;
        twap.set((NAV * 95) / 100, true);
        vm.warp(t0 + 301);
        oracle.setNav(address(rwa), NAV); // keep pools quotable
        vm.warp(t0 + 602); // NAV older than the guard window again
        vm.prank(user);
        vm.expectRevert(); // QuoteOutsideTwapBand
        router.redeemInstant(address(rwa), 10e18, 0);
        assertEq(rwa.balanceOf(address(v4)), 1_000_000e18, "no fill happened");
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

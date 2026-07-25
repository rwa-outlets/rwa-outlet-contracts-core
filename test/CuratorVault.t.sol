// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {OutletTestBase} from "./base/OutletTestBase.sol";
import {CuratorVault} from "../src/CuratorVault.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";

/// @notice CuratorVault as Aqua *contract maker*: LP capital in, pools shipped on the official
///         registry, takers filled through the official router, inventory recycled through the
///         ERC-7540 queue, LP exits at realized values. The full capital-reuse loop.
contract CuratorVaultTest is OutletTestBase {
    OutletRouter internal router;
    RedemptionQueue internal queue;
    CuratorVault internal vault;

    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");
    address internal issuer = makeAddr("issuer");
    address internal treasury = makeAddr("treasury");

    uint16 internal constant CURATOR_FEE_BPS = 10;

    function setUp() public override {
        super.setUp();
        router = new OutletRouter(ISwapVM(address(swapVM)), IERC20(address(usdc)), oracle);
        queue = new RedemptionQueue(
            IERC20(address(rwa)), IERC20(address(usdc)), address(this), issuer, treasury, 5
        );

        vault = new CuratorVault(
            CuratorVault.Config({
                aqua: IAqua(address(aqua)),
                swapVM: ISwapVM(address(swapVM)),
                usdc: IERC20(address(usdc)),
                navOracle: oracle,
                navExtruction: address(navX),
                router: router,
                curator: address(this),
                curatorTreasury: treasury,
                complianceGate: address(0),
                navMaxStaleness: 1 days,
                maxDiscountFloorBps: 300,
                curatorFeeBps: CURATOR_FEE_BPS,
                name: "RWA Outlets Conservative Tier",
                symbol: "outletUSD-A"
            })
        );
        vault.addMandateAsset(address(rwa), queue, 800_000e6);

        usdc.mint(lp, 1_000_000e6);
        usdc.mint(lp2, 1_000_000e6);
        usdc.mint(issuer, 10_000_000e6);
        vm.prank(lp);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(lp2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(issuer);
        usdc.approve(address(queue), type(uint256).max);
    }

    function _depositAndShipExpress(uint256 depositAmt, uint256 shipAmt)
        internal
        returns (bytes32 strategyHash)
    {
        vm.prank(lp);
        vault.deposit(depositAmt, lp);
        strategyHash = vault.createPool(
            address(rwa),
            CuratorVault.PoolKind.Express,
            abi.encode(uint16(20), uint32(1 days), shipAmt, uint256(0))
        );
    }

    /// @dev Pulls the shipped order back out of the router registry (single source of truth).
    function _orderOf(bytes32 strategyHash) internal view returns (ISwapVM.Order memory) {
        return abi.decode(router.orderBlobOf(strategyHash), (ISwapVM.Order));
    }

    // -------------------------------------------------------------- deposits

    function test_DepositSharePriceTracksNav() public {
        vm.prank(lp);
        uint256 shares = vault.deposit(1_000_000e6, lp);
        assertEq(shares, 1_000_000e6 * 1e12, "bootstrap at 1.0");
        assertEq(vault.totalAssets(), 1_000_000e6);

        // vault accrues RWA inventory → share price rises → second LP mints fewer shares
        bytes32 poolHash = vault.createPool(
            address(rwa),
            CuratorVault.PoolKind.Express,
            abi.encode(uint16(20), uint32(1 days), uint256(500_000e6), uint256(0))
        );
        rwa.mint(address(this), 100_000e18);
        swap(_orderOf(poolHash), address(rwa), address(usdc), 100_000e18, true);
        assertGt(vault.totalAssets(), 1_000_000e6, "spread accrues to LPs");

        vm.prank(lp2);
        uint256 shares2 = vault.deposit(1_000_000e6, lp2);
        assertLt(shares2, shares, "later LP pays the higher share price");
    }

    function test_StaleNavBlocksDeposit() public {
        bytes32 poolHash = _depositAndShipExpress(1_000_000e6, 500_000e6);
        rwa.mint(address(this), 1_000e18);
        swap(_orderOf(poolHash), address(rwa), address(usdc), 1_000e18, true); // vault now holds RWA

        vm.warp(block.timestamp + 2 days); // NAV stale
        vm.prank(lp2);
        vm.expectRevert(); // StaleNav
        vault.deposit(1_000e6, lp2);
    }

    // ----------------------------------------------------------------- pools

    function test_CreatePoolShipsAndRegisters() public {
        bytes32 strategyHash = _depositAndShipExpress(1_000_000e6, 500_000e6);

        // official Aqua registry holds the virtual balances, maker = vault
        (uint256 usdcBal,) = aquaBalances(strategyHash, address(vault));
        assertEq(usdcBal, 500_000e6, "shipped virtual USDC");
        assertEq(usdc.balanceOf(address(vault)), 1_000_000e6, "wallet untouched: Aqua is allowances");
        assertEq(vault.shippedUsdcOf(address(rwa)), 500_000e6);

        // router lists it, registrar = vault
        assertEq(router.assetOf(strategyHash), address(rwa));
        assertEq(router.registrarOf(strategyHash), address(vault));

        // taker can fill through the ROUTER path end-to-end
        rwa.mint(address(this), 100e18);
        rwa.approve(address(router), type(uint256).max);
        uint256 out = router.redeemInstant(address(rwa), 100e18, 0);
        assertGt(out, 0, "vault pool serves router takers");
        assertEq(rwa.balanceOf(address(vault)), 100e18, "inventory lands in vault wallet");
    }

    function test_MandateGuards() public {
        vm.prank(lp);
        vault.deposit(1_000_000e6, lp);

        // unknown asset
        vm.expectRevert(
            abi.encodeWithSelector(CuratorVault.AssetNotInMandate.selector, address(usdc))
        );
        vault.createPool(address(usdc), CuratorVault.PoolKind.Express, abi.encode(uint16(20), uint32(1 days), uint256(1e6), uint256(0)));

        // per-asset cap (800k)
        vm.expectRevert(
            abi.encodeWithSelector(
                CuratorVault.AssetCapExceeded.selector, address(rwa), 900_000e6, 800_000e6
            )
        );
        vault.createPool(address(rwa), CuratorVault.PoolKind.Express, abi.encode(uint16(20), uint32(1 days), uint256(900_000e6), uint256(0)));

        // patient auction deeper than mandate floor (300 bps)
        vm.expectRevert(
            abi.encodeWithSelector(CuratorVault.DiscountBeyondMandate.selector, 500, 300)
        );
        vault.createPool(
            address(rwa),
            CuratorVault.PoolKind.Patient,
            abi.encode(uint16(30), uint16(500), uint40(block.timestamp), uint32(3 days), uint32(1 days), uint256(100_000e6))
        );

        // only curator/owner
        vm.prank(lp);
        vm.expectRevert(CuratorVault.NotCurator.selector);
        vault.createPool(address(rwa), CuratorVault.PoolKind.Express, abi.encode(uint16(20), uint32(1 days), uint256(1e6), uint256(0)));
    }

    function test_DockPoolFreesCapitalAndDelists() public {
        bytes32 strategyHash = _depositAndShipExpress(1_000_000e6, 500_000e6);
        ISwapVM.Order memory order = _orderOf(strategyHash); // snapshot before delisting wipes it

        vault.dockPool(strategyHash);
        // docked strategies are inactive: safeBalances reverts by design, rawBalances shows zero
        (uint248 usdcBal,) =
            aqua.rawBalances(address(vault), address(swapVM), strategyHash, address(usdc));
        assertEq(uint256(usdcBal), 0, "virtual balance zeroed");
        assertEq(vault.shippedUsdcOf(address(rwa)), 0);
        assertEq(router.orderBlobOf(strategyHash).length, 0, "delisted");

        // docked pool no longer fills
        rwa.mint(address(this), 10e18);
        vm.expectRevert();
        swap(order, address(rwa), address(usdc), 10e18, true);
    }

    // ------------------------------------------------------- the capital loop

    function test_FullCapitalLoop_LpExitsWithProfit() public {
        bytes32 poolHash = _depositAndShipExpress(1_000_000e6, 500_000e6);

        // 1. taker instant-exits 100k RWA into the vault's Express pool at NAV − 20 bps
        rwa.mint(address(this), 100_000e18);
        (, uint256 paidOut) = swap(_orderOf(poolHash), address(rwa), address(usdc), 100_000e18, true);
        uint256 navValue = (100_000e18 * NAV) / RWA_SCALE; // 104,320e6
        assertLt(paidOut, navValue, "bought below NAV");

        // 2. curator recycles inventory into the issuer queue at full NAV
        vault.recycle(address(rwa), 100_000e18);
        assertEq(vault.queuedShares(address(rwa)), 100_000e18);
        assertGt(vault.totalAssets(), 1_000_000e6, "in-flight shares still valued");

        queue.submitToIssuer(1);
        vm.prank(issuer);
        queue.settle(1, NAV);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        vault.claimQueue(address(rwa), 100_000e18);
        assertEq(vault.queuedShares(address(rwa)), 0);
        assertGt(usdc.balanceOf(treasury), treasuryBefore, "curator ops fee skimmed");

        // 3. LP exits everything at realized value — with profit
        uint256 lpShares = vault.balanceOf(lp);
        vm.startPrank(lp);
        vault.requestRedeem(lpShares, lp, lp);
        vm.stopPrank();

        vault.fulfillRedeemEpoch(1);

        vm.prank(lp);
        uint256 assets = vault.redeem(lpShares, lp, lp);
        assertGt(assets, 1_000_000e6, "LP realized the spread profit");
        assertEq(usdc.balanceOf(lp), assets);
        assertEq(vault.totalSupply(), 0, "full exit burns all shares");
    }

    // --------------------------------------------------------- LP epoch legs

    function test_FulfillRequiresFreeCash() public {
        bytes32 poolHash = _depositAndShipExpress(1_000_000e6, 500_000e6);

        // vault swaps most cash into RWA inventory
        rwa.mint(address(this), 900_000e18);
        swap(_orderOf(poolHash), address(rwa), address(usdc), 480_000e18, true);

        uint256 lpShares = vault.balanceOf(lp);
        vm.prank(lp);
        vault.requestRedeem(lpShares, lp, lp);

        // cash is tied up in inventory → epoch cannot be fulfilled yet
        vm.expectRevert(); // InsufficientFreeCash
        vault.fulfillRedeemEpoch(1);
    }

    function test_RedeemBeforeFulfillmentReverts() public {
        vm.prank(lp);
        vault.deposit(1_000e6, lp);
        uint256 lpShares = vault.balanceOf(lp);

        vm.startPrank(lp);
        vault.requestRedeem(lpShares, lp, lp);
        assertEq(vault.pendingRedeemRequest(1, lp), lpShares);
        assertEq(vault.maxRedeem(lp), 0);
        vm.expectRevert(
            abi.encodeWithSelector(CuratorVault.ExceedsClaimable.selector, lpShares, 0)
        );
        vault.redeem(lpShares, lp, lp);
        vm.stopPrank();
    }

    function test_PreviewsRevertPerErc7540() public {
        vm.expectRevert(CuratorVault.AsyncFlowOnly.selector);
        vault.previewRedeem(1);
        vm.expectRevert(CuratorVault.AsyncFlowOnly.selector);
        vault.previewWithdraw(1);
        assertEq(vault.share(), address(vault), "vault is its own share (7575)");
    }
}

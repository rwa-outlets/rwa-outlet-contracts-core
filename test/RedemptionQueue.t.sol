// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TestUSDC} from "../src/TestUSDC.sol";
import {RWAToken} from "../src/RWAToken.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {IERC7575} from "../src/interfaces/IERC7575.sol";
import {IERC7540Operator, IERC7540Redeem} from "../src/interfaces/IERC7540.sol";

/// @notice Full ERC-7540 queue suite ported from the simulation repo: epoch lifecycle,
///         issuer-window enforcement, FIFO claims, fees, operator model, ERC-165/7575
///         conformance, and the solvency fuzz.
contract RedemptionQueueTest is Test {
    RedemptionQueue queue;
    RWAToken rwa;
    TestUSDC usdc;

    address curator = makeAddr("curator");
    address issuer = makeAddr("issuer");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint16 constant QUEUE_FEE_BPS = 5;
    uint256 constant ISSUER_WINDOW = 90 days; // T+90, enforced onchain
    uint256 constant NAV = 1.0432e18; // rwaCREDIT demo NAV
    // shares(1e18) × nav(1e18) → usdc(1e6): scale = 1e30
    uint256 constant SCALE = 1e30;

    function setUp() public {
        rwa = new RWAToken("Tokenized Private Credit", "rwaCREDIT", IERC721(address(0)));
        usdc = new TestUSDC();
        queue = new RedemptionQueue(
            IERC20(address(rwa)),
            IERC20(address(usdc)),
            curator,
            issuer,
            treasury,
            QUEUE_FEE_BPS,
            ISSUER_WINDOW
        );

        rwa.mint(alice, 1_000_000e18);
        rwa.mint(bob, 1_000_000e18);
        usdc.mint(issuer, 100_000_000e6);

        vm.prank(alice);
        rwa.approve(address(queue), type(uint256).max);
        vm.prank(bob);
        rwa.approve(address(queue), type(uint256).max);
        vm.prank(issuer);
        usdc.approve(address(queue), type(uint256).max);
    }

    // ------------------------------------------------------------ helpers

    function _request(address who, uint256 shares) internal returns (uint256 epoch) {
        vm.prank(who);
        epoch = queue.requestRedeem(shares, who, who);
    }

    function _submitAndSettle(uint256 epoch, uint256 nav) internal {
        vm.prank(curator);
        queue.submitToIssuer(epoch);
        vm.warp(block.timestamp + ISSUER_WINDOW); // wait out the issuer window
        vm.prank(issuer);
        queue.settle(epoch, nav);
    }

    function _grossAssets(uint256 shares, uint256 nav) internal pure returns (uint256) {
        return (shares * nav) / SCALE;
    }

    function _netAssets(uint256 shares, uint256 nav) internal pure returns (uint256) {
        uint256 gross = _grossAssets(shares, nav);
        return gross - (gross * QUEUE_FEE_BPS) / 10_000;
    }

    // ---------------------------------------------------- ERC-7575 shape

    function test_shape() public view {
        assertEq(queue.share(), address(rwa));
        assertEq(queue.asset(), address(usdc));
        assertEq(queue.maxDeposit(address(0)), 0);
        assertEq(queue.maxMint(address(0)), 0);
        assertEq(queue.maxWithdraw(alice), 0);
    }

    function test_syncLegsRevert() public {
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.deposit(1, alice);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.mint(1, alice);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.withdraw(1, alice, alice);
    }

    function test_previewsRevert() public {
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.previewRedeem(1);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.previewWithdraw(1);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.previewDeposit(1);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.previewMint(1);
    }

    // ------------------------------------------------- ERC-165 conformance

    /// @dev Pins our interface definitions to the interface IDs mandated by the EIPs.
    function test_interfaceIds_matchEipConstants() public pure {
        assertEq(type(IERC7540Operator).interfaceId, bytes4(0xe3bc4e65)); // EIP-7540 operator
        assertEq(type(IERC7540Redeem).interfaceId, bytes4(0x620ee8e4)); // EIP-7540 async redeem
        assertEq(type(IERC7575).interfaceId, bytes4(0x2f0a18c5)); // EIP-7575 vault
    }

    function test_supportsInterface() public view {
        assertTrue(queue.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(queue.supportsInterface(0xe3bc4e65)); // ERC-7540 operator
        assertTrue(queue.supportsInterface(0x620ee8e4)); // ERC-7540 async redemption
        assertTrue(queue.supportsInterface(0x2f0a18c5)); // ERC-7575 vault
        assertFalse(queue.supportsInterface(0xce3bbe50)); // ERC-7540 async deposit — not us
        assertFalse(queue.supportsInterface(0xffffffff));
    }

    function test_convertFunctions_useLastSettledNav() public {
        // no exchange rate before the first settlement
        assertEq(queue.convertToAssets(100e18), 0);
        assertEq(queue.convertToShares(100e6), 0);

        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        assertEq(queue.lastSettledNav(), NAV);
        assertEq(queue.convertToAssets(100e18), _grossAssets(100e18, NAV)); // fee excluded
        assertEq(queue.convertToShares(104_320000), 100e18);
    }

    // -------------------------------------------------------- request leg

    function test_requestRedeem_escrowsAndFiles() public {
        uint256 epoch = _request(alice, 100e18);

        assertEq(epoch, 1);
        assertEq(rwa.balanceOf(address(queue)), 100e18);
        assertEq(queue.pendingRedeemRequest(epoch, alice), 100e18);
        assertEq(queue.claimableRedeemRequest(epoch, alice), 0);
        assertEq(queue.maxRedeem(alice), 0);
    }

    function test_requestRedeem_emitsStandardEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IERC7540Redeem.RedeemRequest(alice, alice, 1, alice, 100e18);
        _request(alice, 100e18);
    }

    function test_requestRedeem_zeroSharesReverts() public {
        vm.expectRevert(RedemptionQueue.ZeroShares.selector);
        vm.prank(alice);
        queue.requestRedeem(0, alice, alice);
    }

    function test_requestRedeem_unauthorizedReverts() public {
        vm.expectRevert(RedemptionQueue.NotAuthorized.selector);
        vm.prank(bob);
        queue.requestRedeem(100e18, bob, alice);
    }

    function test_requestRedeem_operatorCanFileForOwner() public {
        vm.prank(alice);
        queue.setOperator(bob, true);
        vm.prank(bob);
        uint256 epoch = queue.requestRedeem(100e18, alice, alice);
        assertEq(queue.pendingRedeemRequest(epoch, alice), 100e18);
    }

    // ------------------------------------------------------- issuer cycle

    function test_submit_onlyCurator() public {
        _request(alice, 100e18);
        vm.expectRevert(RedemptionQueue.NotCurator.selector);
        vm.prank(alice);
        queue.submitToIssuer(1);
    }

    function test_submit_opensNextEpoch() public {
        _request(alice, 100e18);
        vm.prank(curator);
        queue.submitToIssuer(1);

        assertEq(queue.currentEpoch(), 2);
        // new requests file into epoch 2
        uint256 epoch = _request(bob, 50e18);
        assertEq(epoch, 2);
    }

    function test_submit_emptyEpochReverts() public {
        vm.expectRevert(RedemptionQueue.ZeroShares.selector);
        vm.prank(curator);
        queue.submitToIssuer(1);
    }

    function test_settle_onlyIssuer() public {
        _request(alice, 100e18);
        vm.prank(curator);
        queue.submitToIssuer(1);
        vm.expectRevert(RedemptionQueue.NotIssuer.selector);
        vm.prank(alice);
        queue.settle(1, NAV);
    }

    function test_settle_requiresSubmitted() public {
        _request(alice, 100e18);
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.EpochNotSubmitted.selector, 1));
        vm.prank(issuer);
        queue.settle(1, NAV);
    }

    function test_settle_pullsCashAndReleasesRwa() public {
        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        // gross rounded up
        uint256 expected = (100e18 * NAV + SCALE - 1) / SCALE;
        assertEq(usdc.balanceOf(address(queue)), expected);
        assertEq(rwa.balanceOf(address(queue)), 0);
        assertEq(rwa.balanceOf(issuer), 100e18);

        // Claimable state observable — never skipped
        assertEq(queue.pendingRedeemRequest(1, alice), 0);
        assertEq(queue.claimableRedeemRequest(1, alice), 100e18);
        assertEq(queue.maxRedeem(alice), 100e18);
    }

    function test_settle_beforeWindowReverts() public {
        _request(alice, 100e18);
        vm.prank(curator);
        queue.submitToIssuer(1);

        uint256 readyAt = block.timestamp + ISSUER_WINDOW;
        vm.expectRevert(
            abi.encodeWithSelector(RedemptionQueue.IssuerWindowNotElapsed.selector, 1, readyAt)
        );
        vm.prank(issuer);
        queue.settle(1, NAV);

        // one second short still reverts; at readyAt it settles
        vm.warp(readyAt - 1);
        vm.expectRevert(
            abi.encodeWithSelector(RedemptionQueue.IssuerWindowNotElapsed.selector, 1, readyAt)
        );
        vm.prank(issuer);
        queue.settle(1, NAV);

        vm.warp(readyAt);
        vm.prank(issuer);
        queue.settle(1, NAV);
        assertEq(queue.maxRedeem(alice), 100e18);
    }

    function test_settle_outOfOrderReverts() public {
        _request(alice, 100e18);
        vm.prank(curator);
        queue.submitToIssuer(1);
        _request(bob, 50e18);
        vm.prank(curator);
        queue.submitToIssuer(2);

        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.EpochOutOfOrder.selector, 2, 1));
        vm.prank(issuer);
        queue.settle(2, NAV);
    }

    // ---------------------------------------------------------- claim leg

    function test_redeem_paysNavMinusFee() public {
        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        uint256 expected = _netAssets(100e18, NAV);
        vm.prank(alice);
        uint256 assets = queue.redeem(100e18, alice, alice);

        assertEq(assets, expected);
        assertEq(usdc.balanceOf(alice), expected);
        // 100 × 1.0432 = 104.32 USDC gross, fee 5 bps
        assertEq(expected, 104_320000 - (104_320000 * 5) / 10_000);
    }

    function test_redeem_partialClaim() public {
        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        vm.prank(alice);
        queue.redeem(40e18, alice, alice);
        assertEq(queue.maxRedeem(alice), 60e18);

        vm.prank(alice);
        queue.redeem(60e18, alice, alice);
        assertEq(queue.maxRedeem(alice), 0);
    }

    function test_redeem_fifoAcrossEpochs() public {
        // epoch 1: 100 shares @ NAV, epoch 2: 50 shares @ higher NAV
        _request(alice, 100e18);
        vm.prank(curator);
        queue.submitToIssuer(1);
        _request(alice, 50e18);
        vm.prank(curator);
        queue.submitToIssuer(2);

        vm.warp(block.timestamp + ISSUER_WINDOW); // both epochs' windows elapse
        vm.prank(issuer);
        queue.settle(1, NAV);
        uint256 nav2 = 1.05e18;
        vm.prank(issuer);
        queue.settle(2, nav2);

        assertEq(queue.maxRedeem(alice), 150e18);

        // claim 120: 100 from epoch 1 + 20 from epoch 2
        uint256 gross = _grossAssets(100e18, NAV) + _grossAssets(20e18, nav2);
        uint256 expected = gross - (gross * QUEUE_FEE_BPS) / 10_000;
        vm.prank(alice);
        uint256 assets = queue.redeem(120e18, alice, alice);
        assertEq(assets, expected);
        assertEq(queue.maxRedeem(alice), 30e18);
    }

    function test_redeem_stopsAtUnsettledEpoch() public {
        _request(alice, 100e18);
        vm.prank(curator);
        queue.submitToIssuer(1);
        _request(alice, 50e18); // epoch 2, not submitted

        vm.warp(block.timestamp + ISSUER_WINDOW);
        vm.prank(issuer);
        queue.settle(1, NAV);

        assertEq(queue.maxRedeem(alice), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(RedemptionQueue.ExceedsClaimable.selector, 150e18, 100e18)
        );
        vm.prank(alice);
        queue.redeem(150e18, alice, alice);
    }

    function test_redeem_exceedsClaimableReverts() public {
        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        vm.expectRevert(
            abi.encodeWithSelector(RedemptionQueue.ExceedsClaimable.selector, 101e18, 100e18)
        );
        vm.prank(alice);
        queue.redeem(101e18, alice, alice);
    }

    function test_redeem_operatorAutoClaim() public {
        address agent = makeAddr("curatorAgent");
        vm.prank(alice);
        queue.setOperator(agent, true);

        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        // agent claims on alice's behalf, proceeds go to alice
        vm.prank(agent);
        uint256 assets = queue.redeem(100e18, alice, alice);
        assertEq(usdc.balanceOf(alice), assets);
    }

    function test_redeem_unauthorizedReverts() public {
        _request(alice, 100e18);
        _submitAndSettle(1, NAV);

        vm.expectRevert(RedemptionQueue.NotAuthorized.selector);
        vm.prank(bob);
        queue.redeem(100e18, bob, alice);
    }

    // --------------------------------------------------------------- fees

    function test_fees_accrueAndClaim() public {
        _request(alice, 100e18);
        _submitAndSettle(1, NAV);
        vm.prank(alice);
        queue.redeem(100e18, alice, alice);

        uint256 gross = _grossAssets(100e18, NAV);
        uint256 fee = (gross * QUEUE_FEE_BPS) / 10_000;
        assertEq(queue.accruedFees(), fee);

        queue.claimFees();
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(queue.accruedFees(), 0);
    }

    // -------------------------------------------------------------- admin

    function test_setRoles_emitsRolesSet() public {
        address newCurator = makeAddr("newCurator");
        address newIssuer = makeAddr("newIssuer");
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(address(queue));
        emit RedemptionQueue.RolesSet(newCurator, newIssuer, newTreasury);
        queue.setRoles(newCurator, newIssuer, newTreasury);

        assertEq(queue.curator(), newCurator);
        assertEq(queue.issuer(), newIssuer);
        assertEq(queue.feeRecipient(), newTreasury);
    }

    // --------------------------------------------------- multi-controller

    function test_multiController_sameEpoch() public {
        _request(alice, 100e18);
        _request(bob, 200e18);
        _submitAndSettle(1, NAV);

        vm.prank(alice);
        uint256 aliceAssets = queue.redeem(100e18, alice, alice);
        vm.prank(bob);
        uint256 bobAssets = queue.redeem(200e18, bob, bob);

        assertEq(aliceAssets, _netAssets(100e18, NAV));
        assertEq(bobAssets, _netAssets(200e18, NAV));
    }

    // ------------------------------------------------------ decimal fuzz

    function testFuzz_redeem_neverOverpays(uint256 shares, uint256 nav) public {
        shares = bound(shares, 1, 1_000_000e18);
        nav = bound(nav, 0.5e18, 2e18);

        _request(alice, shares);
        _submitAndSettle(1, nav);

        uint256 queueBalBefore = usdc.balanceOf(address(queue));
        vm.prank(alice);
        uint256 assets = queue.redeem(shares, alice, alice);

        // payout + accrued fees never exceed settlement cash received (solvency)
        assertLe(assets + queue.accruedFees(), queueBalBefore);
    }
}

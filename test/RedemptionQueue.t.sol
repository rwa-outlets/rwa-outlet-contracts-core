// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TestUSDC} from "../src/TestUSDC.sol";
import {RWAToken} from "../src/RWAToken.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";

/// @notice Port-parity suite for the ERC-7540 queue (logic validated in the simulation repo):
///         full epoch lifecycle, FIFO claims, fees, operator model, disabled deposit side.
contract RedemptionQueueTest is Test {
    uint256 internal constant NAV = 1.05e18;
    uint256 internal constant SCALE = 1e30; // 10^(18 + 18 - 6)
    uint16 internal constant FEE_BPS = 5;

    TestUSDC internal usdc;
    RWAToken internal rwa;
    RedemptionQueue internal queue;

    address internal curator = makeAddr("curator");
    address internal issuer = makeAddr("issuer");
    address internal treasury = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        usdc = new TestUSDC();
        rwa = new RWAToken("Tokenized T-Bill", "rwaTBILL", IERC721(address(0)));
        queue = new RedemptionQueue(
            IERC20(address(rwa)), IERC20(address(usdc)), curator, issuer, treasury, FEE_BPS
        );

        rwa.mint(alice, 1_000e18);
        rwa.mint(bob, 1_000e18);
        usdc.mint(issuer, 10_000_000e6);
        vm.prank(alice);
        rwa.approve(address(queue), type(uint256).max);
        vm.prank(bob);
        rwa.approve(address(queue), type(uint256).max);
        vm.prank(issuer);
        usdc.approve(address(queue), type(uint256).max);
    }

    function _grossOut(uint256 shares) internal pure returns (uint256) {
        return (shares * NAV + SCALE - 1) / SCALE;
    }

    // ------------------------------------------------------------- lifecycle

    function test_FullLifecycle() public {
        // request: shares escrowed into epoch 1
        vm.prank(alice);
        uint256 reqId = queue.requestRedeem(100e18, alice, alice);
        assertEq(reqId, 1);
        assertEq(rwa.balanceOf(address(queue)), 100e18, "escrowed");
        assertEq(queue.pendingRedeemRequest(1, alice), 100e18);
        assertEq(queue.claimableRedeemRequest(1, alice), 0);

        // submit: epoch 1 batched, epoch 2 opens
        vm.prank(curator);
        queue.submitToIssuer(1);
        assertEq(queue.currentEpoch(), 2);
        assertEq(queue.pendingRedeemRequest(1, alice), 100e18, "still pending until settled");

        // settle: issuer delivers cash at NAV, escrowed RWA released to issuer
        uint256 gross = _grossOut(100e18); // 105e6
        vm.prank(issuer);
        queue.settle(1, NAV);
        assertEq(usdc.balanceOf(address(queue)), gross, "settlement cash in");
        assertEq(rwa.balanceOf(issuer), 100e18, "RWA handed to issuer");
        assertEq(queue.pendingRedeemRequest(1, alice), 0);
        assertEq(queue.claimableRedeemRequest(1, alice), 100e18);
        assertEq(queue.maxRedeem(alice), 100e18);

        // claim: alice receives gross minus 5 bps queue fee
        uint256 fee = (gross * FEE_BPS) / 10_000;
        vm.prank(alice);
        uint256 assets = queue.redeem(100e18, alice, alice);
        assertEq(assets, gross - fee, "net of queue fee");
        assertEq(usdc.balanceOf(alice), gross - fee);
        assertEq(queue.accruedFees(), fee);

        // fee treasury withdrawal
        queue.claimFees();
        assertEq(usdc.balanceOf(treasury), fee);
    }

    function test_FifoAcrossEpochs() public {
        // epoch 1: 100 shares; epoch 2: 50 shares
        vm.prank(alice);
        queue.requestRedeem(100e18, alice, alice);
        vm.prank(curator);
        queue.submitToIssuer(1);
        vm.prank(alice);
        queue.requestRedeem(50e18, alice, alice);
        vm.prank(curator);
        queue.submitToIssuer(2);

        // only epoch 1 settled → maxRedeem stops at FIFO boundary
        vm.prank(issuer);
        queue.settle(1, NAV);
        assertEq(queue.maxRedeem(alice), 100e18, "epoch 2 not claimable yet");

        // claiming across the boundary reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.ExceedsClaimable.selector, 150e18, 100e18));
        queue.redeem(150e18, alice, alice);

        // settle epoch 2 → full claim drains both epochs in order
        vm.prank(issuer);
        queue.settle(2, NAV);
        vm.prank(alice);
        uint256 assets = queue.redeem(150e18, alice, alice);
        uint256 gross = (150e18 * NAV) / SCALE;
        assertEq(assets, gross - (gross * FEE_BPS) / 10_000);
    }

    function test_TwoControllersProRata() public {
        vm.prank(alice);
        queue.requestRedeem(100e18, alice, alice);
        vm.prank(bob);
        queue.requestRedeem(300e18, bob, bob);

        vm.prank(curator);
        queue.submitToIssuer(1);
        vm.prank(issuer);
        queue.settle(1, NAV);

        vm.prank(bob);
        uint256 bobAssets = queue.redeem(300e18, bob, bob);
        vm.prank(alice);
        uint256 aliceAssets = queue.redeem(100e18, alice, alice);
        assertEq(bobAssets, aliceAssets * 3, "settlement is per-share");
    }

    // ----------------------------------------------------------- guardrails

    function test_SettleOutOfOrderReverts() public {
        vm.prank(alice);
        queue.requestRedeem(10e18, alice, alice);
        vm.prank(curator);
        queue.submitToIssuer(1);
        vm.prank(alice);
        queue.requestRedeem(10e18, alice, alice);
        vm.prank(curator);
        queue.submitToIssuer(2);

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(RedemptionQueue.EpochOutOfOrder.selector, 2, 1));
        queue.settle(2, NAV);
    }

    function test_RoleGates() public {
        vm.prank(alice);
        queue.requestRedeem(10e18, alice, alice);

        vm.expectRevert(RedemptionQueue.NotCurator.selector);
        queue.submitToIssuer(1);

        vm.prank(curator);
        queue.submitToIssuer(1);

        vm.expectRevert(RedemptionQueue.NotIssuer.selector);
        queue.settle(1, NAV);
    }

    function test_OperatorModel() public {
        address agent = makeAddr("agent");

        // agent cannot act for alice until approved
        vm.prank(agent);
        vm.expectRevert(RedemptionQueue.NotAuthorized.selector);
        queue.requestRedeem(10e18, alice, alice);

        vm.prank(alice);
        queue.setOperator(agent, true);
        vm.prank(agent);
        queue.requestRedeem(10e18, alice, alice);

        vm.prank(curator);
        queue.submitToIssuer(1);
        vm.prank(issuer);
        queue.settle(1, NAV);

        // agent claims on alice's behalf, proceeds go to alice
        vm.prank(agent);
        queue.redeem(10e18, alice, alice);
        assertGt(usdc.balanceOf(alice), 0);
    }

    function test_DepositSideDisabled() public {
        assertEq(queue.maxDeposit(alice), 0);
        assertEq(queue.maxMint(alice), 0);
        assertEq(queue.maxWithdraw(alice), 0);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.deposit(1, alice);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.mint(1, alice);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.withdraw(1, alice, alice);
        vm.expectRevert(RedemptionQueue.AsyncFlowOnly.selector);
        queue.previewRedeem(1);
    }

    function test_Erc7575Shape() public view {
        assertEq(queue.share(), address(rwa), "external share = RWA token");
        assertEq(queue.asset(), address(usdc));
    }
}

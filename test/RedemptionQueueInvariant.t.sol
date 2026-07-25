// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {TestUSDC} from "../src/TestUSDC.sol";
import {RWAToken} from "../src/RWAToken.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";

/// @dev Randomized actor that drives the queue through its full lifecycle.
contract QueueHandler is Test {
    RedemptionQueue public immutable queue;
    RWAToken public immutable rwa;
    TestUSDC public immutable usdc;

    address public immutable curator;
    address public immutable issuer;

    address[] public holders;
    uint256 public totalClaimedAssets; // net USDC paid to holders
    uint256 public totalFeesClaimed;

    uint256 constant SCALE = 1e30;

    constructor(
        RedemptionQueue queue_,
        RWAToken rwa_,
        TestUSDC usdc_,
        address curator_,
        address issuer_
    ) {
        queue = queue_;
        rwa = rwa_;
        usdc = usdc_;
        curator = curator_;
        issuer = issuer_;
    }

    /// @dev Called after this handler receives token ownership.
    function init() external {
        for (uint256 i = 0; i < 4; i++) {
            address h = makeAddr(string(abi.encodePacked("holder", i)));
            holders.push(h);
            rwa.mint(h, 10_000_000e18);
            vm.prank(h);
            rwa.approve(address(queue), type(uint256).max);
        }
        usdc.mint(issuer, type(uint128).max);
        vm.prank(issuer);
        usdc.approve(address(queue), type(uint256).max);
    }

    function requestRedeem(uint256 holderSeed, uint256 shares) external {
        address h = holders[holderSeed % holders.length];
        if (rwa.balanceOf(h) == 0) return;
        shares = bound(shares, 1, rwa.balanceOf(h));
        vm.prank(h);
        queue.requestRedeem(shares, h, h);
    }

    function submit() external {
        uint256 epoch = queue.currentEpoch();
        if (queue.epochInfo(epoch).totalShares == 0) return;
        vm.prank(curator);
        queue.submitToIssuer(epoch);
    }

    function settle(uint256 navSeed) external {
        uint256 epoch = queue.lastSettledEpoch() + 1;
        RedemptionQueue.Epoch memory e = queue.epochInfo(epoch);
        if (e.state != RedemptionQueue.EpochState.Submitted) return;
        // wait out the onchain issuer window before settling
        uint256 readyAt = e.submittedAt + queue.issuerWindow();
        if (block.timestamp < readyAt) vm.warp(readyAt);
        uint256 nav = bound(navSeed, 0.9e18, 1.2e18);
        vm.prank(issuer);
        queue.settle(epoch, nav);
    }

    function claim(uint256 holderSeed, uint256 shares) external {
        address h = holders[holderSeed % holders.length];
        uint256 max = queue.maxRedeem(h);
        if (max == 0) return;
        shares = bound(shares, 1, max);
        vm.prank(h);
        totalClaimedAssets += queue.redeem(shares, h, h);
    }

    function claimFees() external {
        totalFeesClaimed += queue.accruedFees();
        queue.claimFees();
    }

    // ------------------------------------------------------ ghost helpers

    /// @dev Gross value still owed for claimable (settled, unclaimed) shares, floor-rounded.
    function outstandingClaimableGross() external view returns (uint256 total) {
        uint256 last = queue.lastSettledEpoch();
        for (uint256 ep = 1; ep <= last; ep++) {
            RedemptionQueue.Epoch memory e = queue.epochInfo(ep);
            for (uint256 i = 0; i < holders.length; i++) {
                uint256 shares = queue.sharesAt(ep, holders[i]);
                total += (shares * e.navAtSettle) / SCALE;
            }
        }
    }

    /// @dev Shares escrowed but not yet settled (pending epochs).
    function pendingShares() external view returns (uint256 total) {
        uint256 current = queue.currentEpoch();
        for (uint256 ep = queue.lastSettledEpoch() + 1; ep <= current; ep++) {
            total += queue.epochInfo(ep).totalShares;
        }
    }
}

contract RedemptionQueueInvariantTest is Test {
    RedemptionQueue queue;
    RWAToken rwa;
    TestUSDC usdc;
    QueueHandler handler;

    address curator = makeAddr("curator");
    address issuer = makeAddr("issuer");
    address treasury = makeAddr("treasury");

    function setUp() public {
        rwa = new RWAToken("Tokenized Private Credit", "rwaCREDIT", IERC721(address(0)));
        usdc = new TestUSDC();
        queue = new RedemptionQueue(
            IERC20(address(rwa)), IERC20(address(usdc)), curator, issuer, treasury, 5, 90 days
        );
        handler = new QueueHandler(queue, rwa, usdc, curator, issuer);
        rwa.transferOwnership(address(handler));
        usdc.transferOwnership(address(handler));
        handler.init();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = QueueHandler.requestRedeem.selector;
        selectors[1] = QueueHandler.submit.selector;
        selectors[2] = QueueHandler.settle.selector;
        selectors[3] = QueueHandler.claim.selector;
        selectors[4] = QueueHandler.claimFees.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Structural solvency: the queue always holds enough USDC to pay every
    ///         claimable (settled, unclaimed) request in full plus already-accrued fees.
    /// @dev Settlement pulls gross rounded UP and claims round DOWN, so the balance always
    ///      covers the outstanding gross (which itself contains the future fee split).
    function invariant_solvency() public view {
        assertGe(
            usdc.balanceOf(address(queue)),
            handler.outstandingClaimableGross() + queue.accruedFees()
        );
    }

    /// @notice Escrow conservation: RWA held == shares in epochs not yet settled.
    function invariant_escrowMatchesPending() public view {
        assertEq(rwa.balanceOf(address(queue)), handler.pendingShares());
    }

    /// @notice USDC conservation: the fee accounting never exceeds what's held.
    function invariant_cashConservation() public view {
        assertGe(usdc.balanceOf(address(queue)), queue.accruedFees());
    }
}

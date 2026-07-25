// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NavOracle} from "../src/NavOracle.sol";
import {ComplianceNFT} from "../src/ComplianceNFT.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {CuratorVault} from "../src/CuratorVault.sol";

/// @notice Indexer-data generator for the Sepolia deployment: repeatable "market rounds" that
///         emit the full event surface the subgraph indexes — NavUpdated series, Trade /
///         Swapped / Pulled / Pushed in both directions, PoolCreated / PoolDocked rebalances,
///         multi-epoch RedeemRequest → Submitted → Settled → Withdraw cycles from several
///         controllers, Deposit events from multiple LPs, FeesClaimed, and ComplianceNFT
///         mint/revoke churn. Orchestrated by script/run-sepolia-scenarios.sh (assumes
///         run-sepolia-flows.sh has run once: pools exist and approvals/operators are set).
contract SepoliaScenarios is Script {
    NavOracle oracle;
    ComplianceNFT kyc;
    IERC20 usdc;
    IERC20 tbill;
    IERC20 credit;
    RedemptionQueue tbillQueue;
    RedemptionQueue creditQueue;
    OutletRouter router;
    CuratorVault expressVault;
    CuratorVault patientVault;

    function _load() internal {
        string memory json =
            vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        oracle = NavOracle(vm.parseJsonAddress(json, ".NavOracle"));
        kyc = ComplianceNFT(vm.parseJsonAddress(json, ".ComplianceNFT"));
        usdc = IERC20(vm.parseJsonAddress(json, ".TestUSDC"));
        tbill = IERC20(vm.parseJsonAddress(json, ".rwaTBILL"));
        credit = IERC20(vm.parseJsonAddress(json, ".rwaCREDIT"));
        tbillQueue = RedemptionQueue(vm.parseJsonAddress(json, ".RedemptionQueue_rwaTBILL"));
        creditQueue = RedemptionQueue(vm.parseJsonAddress(json, ".RedemptionQueue_rwaCREDIT"));
        router = OutletRouter(vm.parseJsonAddress(json, ".OutletRouter"));
        expressVault = CuratorVault(vm.parseJsonAddress(json, ".CuratorVault_Express"));
        patientVault = CuratorVault(vm.parseJsonAddress(json, ".CuratorVault_Patient"));
    }

    // ------------------------------------------------- deployer (keeper)

    /// @notice NAV keeper tick: yield accrual plus a little block-hash noise, one NavUpdated
    ///         per asset per round — builds the NavPoint time series.
    function navDrift() external {
        _load();
        (uint256 navT,) = oracle.navOf(address(tbill));
        (uint256 navC,) = oracle.navOf(address(credit));
        uint256 noise = uint256(blockhash(block.number - 1)) % 3; // 0-2 bps
        navT = (navT * (10_000 + 1 + noise)) / 10_000; // ~T-bill accrual
        navC = (navC * (10_000 + 2 + noise)) / 10_000; // ~credit accrual
        vm.startBroadcast();
        oracle.setNav(address(tbill), navT);
        oracle.setNav(address(credit), navC);
        vm.stopBroadcast();
        console2.log("nav TBILL", navT);
        console2.log("nav CRED ", navC);
    }

    // --------------------------------------------------------- trader (M2)

    /// @notice Trade burst: two Express exits, one decay-auction exit, one Market/bid entry,
    ///         plus a small Patient-vault deposit — Trade events in both directions from a
    ///         second LP address.
    function traderBurst() external {
        _load();
        vm.startBroadcast();
        tbill.approve(address(router), type(uint256).max);
        credit.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        usdc.approve(address(patientVault), type(uint256).max);

        uint256 out1 = _exit(address(tbill), 15e18);
        uint256 out2 = _exit(address(tbill), 25e18);
        uint256 out3 = _exit(address(credit), 10e18);
        (bytes32 hb, uint256 qb) = router.quoteBuy(address(credit), 10e6);
        uint256 out4;
        if (hb != bytes32(0)) out4 = router.buy(address(credit), 10e6, (qb * 97) / 100);
        patientVault.deposit(30e6, msg.sender);
        vm.stopBroadcast();
        console2.log("exits", out1, out2, out3);
        console2.log("buy CRED out", out4);
    }

    /// @notice Trader's own patient exit: files 30 TBILL into the tbill queue (second
    ///         controller in the epoch alongside the vault's recycled inventory).
    function traderQueue() external {
        _load();
        vm.startBroadcast();
        tbill.approve(address(tbillQueue), type(uint256).max);
        uint256 epoch = tbillQueue.requestRedeem(30e18, msg.sender, msg.sender);
        vm.stopBroadcast();
        console2.log("trader queued 30 TBILL in epoch", epoch);
    }

    /// @notice Trader self-claims settled tbill epochs (Withdraw event from an EOA).
    function traderClaim() external {
        _load();
        uint256 m = tbillQueue.maxRedeem(msg.sender);
        vm.startBroadcast();
        if (m > 0) tbillQueue.redeem(m, msg.sender, msg.sender);
        vm.stopBroadcast();
        console2.log("trader claimed shares", m);
    }

    // ---------------------------------------------------------- maker (M4)

    /// @notice Maker doubles as an Express-tier LP — Deposit events from a third address.
    function makerDeposit() external {
        _load();
        vm.startBroadcast();
        usdc.approve(address(expressVault), type(uint256).max);
        uint256 shares = expressVault.deposit(50e6, msg.sender);
        vm.stopBroadcast();
        console2.log("maker roEXP shares", shares);
    }

    // -------------------------------------------------------- patient (M3)

    /// @notice Small repeat queue request each round — multi-epoch history for one controller.
    function patientQueue() external {
        _load();
        vm.startBroadcast();
        uint256 epoch = creditQueue.requestRedeem(20e18, msg.sender, msg.sender);
        vm.stopBroadcast();
        console2.log("patient queued 20 CRED in epoch", epoch);
    }

    // ------------------------------------------------ deployer (curator)

    /// @notice Recycles vault inventory and batches every non-empty queue epoch.
    function curatorSubmit() external {
        _load();
        uint256 invT = tbill.balanceOf(address(expressVault));
        uint256 invC = credit.balanceOf(address(patientVault));
        vm.startBroadcast();
        if (invT > 0) expressVault.recycle(address(tbill), invT);
        if (invC > 0) patientVault.recycle(address(credit), invC);
        if (tbillQueue.epochInfo(tbillQueue.currentEpoch()).totalShares > 0) {
            tbillQueue.submitToIssuer(tbillQueue.currentEpoch());
        }
        if (creditQueue.epochInfo(creditQueue.currentEpoch()).totalShares > 0) {
            creditQueue.submitToIssuer(creditQueue.currentEpoch());
        }
        vm.stopBroadcast();
        console2.log("recycled TBILL/CRED", invT, invC);
    }

    /// @notice Issuer settlement + operator auto-claims + vault harvest + fee sweeps —
    ///         the full Settled / Withdraw / FeesClaimed surface. Run after the windows.
    function settleOps() external {
        _load();
        address patient = vm.envAddress("PATIENT_ADDR");
        vm.startBroadcast();
        _settleNext(tbillQueue, address(tbill));
        _settleNext(creditQueue, address(credit));

        uint256 p = creditQueue.maxRedeem(patient);
        if (p > 0) creditQueue.redeem(p, patient, patient);
        uint256 vt = tbillQueue.maxRedeem(address(expressVault));
        if (vt > 0) expressVault.claimQueue(address(tbill), vt);
        uint256 vc = creditQueue.maxRedeem(address(patientVault));
        if (vc > 0) patientVault.claimQueue(address(credit), vc);

        if (tbillQueue.accruedFees() > 0) tbillQueue.claimFees();
        if (creditQueue.accruedFees() > 0) creditQueue.claimFees();
        vm.stopBroadcast();
        console2.log("settled + claimed; patient claim", p);
    }

    /// @notice Curator rebalance: docks the active Express pool and re-ships at a new spread
    ///         — PoolDocked + PoolCreated + Docked/Shipped every round.
    function rebalanceExpress() external {
        _load();
        bytes32 active;
        for (uint256 i = expressVault.poolCount(); i > 0; i--) {
            bytes32 h = expressVault.poolHashes(i - 1);
            (address asset_,, bool isActive) = expressVault.pools(h);
            if (isActive && asset_ == address(tbill)) {
                active = h;
                break;
            }
        }
        uint16 spread = uint16(10 + (uint256(blockhash(block.number - 1)) % 15)); // 10-24 bps
        uint256 free = usdc.balanceOf(address(expressVault)) - expressVault.reservedAssets();
        uint256 shipAmt = free / 2;
        vm.startBroadcast();
        if (active != bytes32(0)) expressVault.dockPool(active);
        expressVault.createPool(
            address(tbill),
            CuratorVault.PoolKind.Express,
            abi.encode(spread, uint32(24 hours), shipAmt, uint256(0))
        );
        vm.stopBroadcast();
        console2.log("re-shipped express, spread bps", spread);
        console2.log("shipped USDC", shipAmt);
    }

    /// @notice KYC churn: mint + revoke a pass for a synthetic address — Transfer events
    ///         that keep the subgraph's KYC set moving.
    function kycChurn() external {
        _load();
        address ghost = address(
            uint160(uint256(keccak256(abi.encode(block.timestamp, blockhash(block.number - 1)))))
        );
        vm.startBroadcast();
        kyc.mint(ghost);
        kyc.revoke(ghost);
        vm.stopBroadcast();
        console2.log("kyc churned", ghost);
    }

    // ------------------------------------------------------------- helpers

    function _exit(address asset, uint256 amount) private returns (uint256 out) {
        (bytes32 h, uint256 q) = router.quoteInstant(asset, amount);
        if (h == bytes32(0)) return 0;
        out = router.redeemInstant(asset, amount, (q * 97) / 100);
    }

    function _settleNext(RedemptionQueue queue, address) private {
        uint256 epoch = queue.lastSettledEpoch() + 1;
        RedemptionQueue.Epoch memory e = queue.epochInfo(epoch);
        if (e.state != RedemptionQueue.EpochState.Submitted) return;
        if (block.timestamp < e.submittedAt + queue.issuerWindow()) return;
        (uint256 nav,) = oracle.navOf(queue.share());
        usdc.approve(address(queue), type(uint256).max);
        queue.settle(epoch, nav);
    }
}

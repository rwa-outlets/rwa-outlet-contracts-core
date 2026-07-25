// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {NavOracle} from "../src/NavOracle.sol";
import {ComplianceNFT} from "../src/ComplianceNFT.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {CuratorVault} from "../src/CuratorVault.sol";

interface IFaucet {
    function setComplianceNFT(address nft_) external;
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @notice Rebinds the Sepolia stack to the faucet repo's live demo tokens (the faucet mints
///         them to visitors, so the outlet contracts must trade THOSE addresses). Token-bound
///         contracts (queues, router, vaults) redeploy; Aqua, AquaSwapVMRouter, NavOracle,
///         NavExtruction, and ComplianceNFT are reused from deployments/<chainid>.json.
///         Also registers the ComplianceNFT with the faucet (operator + setComplianceNFT) so
///         every drip hands out a KYC pass. Re-run DeployHook.s.sol afterwards — the hook
///         binds USDC immutably too.
contract RewireFaucetTokens is Script {
    // faucet repo deployments on Ethereum Sepolia
    address constant FAUCET = 0xE78E87D994358D17aaf4653d8398f22C93fb758A;
    address constant USDC = 0x062b2F19C852e486b4b913933420957018d1db31; // 6d
    address constant TBILL = 0x5456E52531085291a35CF0d902aE72D6616b665D; // 18d
    address constant CREDIT = 0xFbca2B3334138C109D51f5101343DE0A35a0eDD9; // 18d

    uint256 constant NAV_TBILL = 1.0021e18;
    uint256 constant NAV_CREDIT = 1.0432e18;
    uint256 constant WINDOW_TBILL = 60; // compressed T+7
    uint256 constant WINDOW_CREDIT = 90; // compressed T+90
    uint16 constant QUEUE_FEE_BPS = 5;
    uint32 constant NAV_MAX_STALENESS = 24 hours;

    function run() external {
        require(block.chainid == 11155111, "Sepolia only");
        string memory path =
            string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address aqua = vm.parseJsonAddress(json, ".Aqua");
        address swapVM = vm.parseJsonAddress(json, ".AquaSwapVMRouter");
        NavOracle oracle = NavOracle(vm.parseJsonAddress(json, ".NavOracle"));
        address navX = vm.parseJsonAddress(json, ".NavExtruction");
        ComplianceNFT kyc = ComplianceNFT(vm.parseJsonAddress(json, ".ComplianceNFT"));

        vm.startBroadcast();
        address deployer = msg.sender;

        // ---- token-bound stack, rebound to the faucet tokens
        RedemptionQueue tbillQueue = new RedemptionQueue(
            IERC20(TBILL), IERC20(USDC), deployer, deployer, deployer,
            QUEUE_FEE_BPS, WINDOW_TBILL
        );
        RedemptionQueue creditQueue = new RedemptionQueue(
            IERC20(CREDIT), IERC20(USDC), deployer, deployer, deployer,
            QUEUE_FEE_BPS, WINDOW_CREDIT
        );
        OutletRouter router = new OutletRouter(ISwapVM(swapVM), IERC20(USDC), oracle);

        CuratorVault expressVault = new CuratorVault(
            CuratorVault.Config({
                aqua: IAqua(aqua),
                swapVM: ISwapVM(swapVM),
                usdc: IERC20(USDC),
                navOracle: oracle,
                navExtruction: navX,
                router: router,
                curator: deployer,
                curatorTreasury: deployer,
                complianceGate: address(0),
                navMaxStaleness: NAV_MAX_STALENESS,
                maxDiscountFloorBps: 25,
                curatorFeeBps: 10,
                name: "RWA Outlets Express Tier",
                symbol: "roEXP"
            })
        );
        CuratorVault patientVault = new CuratorVault(
            CuratorVault.Config({
                aqua: IAqua(aqua),
                swapVM: ISwapVM(swapVM),
                usdc: IERC20(USDC),
                navOracle: oracle,
                navExtruction: navX,
                router: router,
                curator: deployer,
                curatorTreasury: deployer,
                complianceGate: address(0),
                navMaxStaleness: NAV_MAX_STALENESS,
                maxDiscountFloorBps: 300,
                curatorFeeBps: 10,
                name: "RWA Outlets Patient Tier",
                symbol: "roPAT"
            })
        );

        // ---- wiring
        oracle.setNav(TBILL, NAV_TBILL);
        oracle.setNav(CREDIT, NAV_CREDIT);
        router.setQueue(TBILL, tbillQueue);
        router.setQueue(CREDIT, creditQueue);
        expressVault.addMandateAsset(TBILL, tbillQueue, 500_000e6);
        patientVault.addMandateAsset(CREDIT, creditQueue, 150_000e6);

        // ---- faucet hands out the KYC pass with every drip
        kyc.setOperator(FAUCET, true);
        IFaucet(FAUCET).setComplianceNFT(address(kyc));

        // ---- demo funding for pool seeding (deployer owns the faucet tokens)
        IMintable(USDC).mint(deployer, 2_000_000e6);
        IMintable(TBILL).mint(deployer, 1_000_000e18);
        IMintable(CREDIT).mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        // ---- rewrite deployments/<chainid>.json
        string memory o = "rewire";
        vm.serializeAddress(o, "Aqua", aqua);
        vm.serializeAddress(o, "AquaSwapVMRouter", swapVM);
        vm.serializeAddress(o, "NavOracle", address(oracle));
        vm.serializeAddress(o, "NavExtruction", navX);
        vm.serializeAddress(o, "ComplianceNFT", address(kyc));
        vm.serializeAddress(o, "Faucet", FAUCET);
        vm.serializeAddress(o, "TestUSDC", USDC);
        vm.serializeAddress(o, "rwaTBILL", TBILL);
        vm.serializeAddress(o, "rwaCREDIT", CREDIT);
        vm.serializeAddress(o, "RedemptionQueue_rwaTBILL", address(tbillQueue));
        vm.serializeAddress(o, "RedemptionQueue_rwaCREDIT", address(creditQueue));
        vm.serializeAddress(o, "OutletRouter", address(router));
        vm.serializeAddress(o, "CuratorVault_Express", address(expressVault));
        vm.serializeAddress(o, "CuratorVault_Patient", address(patientVault));
        vm.serializeAddress(o, "RWAGateHook", address(0)); // filled by DeployHook.s.sol
        string memory out = vm.serializeAddress(o, "deployer", deployer);
        vm.writeJson(out, path);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {AquaSwapVMRouter} from "swap-vm/src/routers/AquaSwapVMRouter.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {NavOracle} from "../src/NavOracle.sol";
import {NavExtruction} from "../src/NavExtruction.sol";
import {ComplianceNFT} from "../src/ComplianceNFT.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {RWAToken} from "../src/RWAToken.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {CuratorVault} from "../src/CuratorVault.sol";

/// @notice Full RWA Outlets stack on a public testnet (Ethereum Sepolia). The official 1inch
///         Aqua + AquaSwapVMRouter are REDEPLOYS of the untouched vendored bytecode (allowed
///         per docs/03-contracts.md §0 — never reimplemented). The v4 RWAGateHook deploys
///         separately (DeployHook.s.sol, solc 0.8.26 unit).
///
///         Roles (curator/issuer/keeper) all start as the deployer; hand them to the agent
///         and issuer keepers later via the setters.
contract Deploy is Script {
    // demo NAVs
    uint256 constant NAV_TBILL = 1.0021e18;
    uint256 constant NAV_CREDIT = 1.0432e18;
    // compressed issuer windows for the demo (docs: "60 s = T+90")
    uint256 constant WINDOW_TBILL = 60; // T+7
    uint256 constant WINDOW_CREDIT = 90; // T+90
    uint16 constant QUEUE_FEE_BPS = 5;
    uint32 constant NAV_MAX_STALENESS = 24 hours;

    function run() external {
        // Official 1inch stack: redeployed via `forge create` (forge-script constructor-arg
        // decoding chokes on the router artifact), addresses passed in by env.
        Aqua aqua = Aqua(payable(vm.envAddress("AQUA")));
        AquaSwapVMRouter swapVM = AquaSwapVMRouter(payable(vm.envAddress("SWAP_VM")));

        vm.startBroadcast();
        address deployer = msg.sender;

        // ---- primitives
        NavOracle oracle = new NavOracle();
        NavExtruction navX = new NavExtruction(oracle);
        ComplianceNFT kyc = new ComplianceNFT();
        TestUSDC usdc = new TestUSDC();
        RWAToken tbill = new RWAToken("Tokenized T-Bill Fund", "rwaTBILL", IERC721(address(kyc)));
        RWAToken credit =
            new RWAToken("Tokenized Private Credit", "rwaCREDIT", IERC721(address(kyc)));

        // ---- queues (one per asset), router
        RedemptionQueue tbillQueue = new RedemptionQueue(
            IERC20(address(tbill)), IERC20(address(usdc)), deployer, deployer, deployer,
            QUEUE_FEE_BPS, WINDOW_TBILL
        );
        RedemptionQueue creditQueue = new RedemptionQueue(
            IERC20(address(credit)), IERC20(address(usdc)), deployer, deployer, deployer,
            QUEUE_FEE_BPS, WINDOW_CREDIT
        );
        OutletRouter router = new OutletRouter(ISwapVM(address(swapVM)), IERC20(address(usdc)), oracle);

        // ---- tier vaults (Express = T-bill assets, Patient = private credit)
        CuratorVault expressVault = new CuratorVault(
            CuratorVault.Config({
                aqua: IAqua(address(aqua)),
                swapVM: ISwapVM(address(swapVM)),
                usdc: IERC20(address(usdc)),
                navOracle: oracle,
                navExtruction: address(navX),
                router: router,
                curator: deployer,
                curatorTreasury: deployer,
                complianceGate: address(0), // program-level gate open for the demo
                navMaxStaleness: NAV_MAX_STALENESS,
                maxDiscountFloorBps: 25, // Express tier: 5-25 bps spreads
                curatorFeeBps: 10,
                name: "RWA Outlets Express Tier",
                symbol: "roEXP"
            })
        );
        CuratorVault patientVault = new CuratorVault(
            CuratorVault.Config({
                aqua: IAqua(address(aqua)),
                swapVM: ISwapVM(address(swapVM)),
                usdc: IERC20(address(usdc)),
                navOracle: oracle,
                navExtruction: address(navX),
                router: router,
                curator: deployer,
                curatorTreasury: deployer,
                complianceGate: address(0),
                navMaxStaleness: NAV_MAX_STALENESS,
                maxDiscountFloorBps: 300, // Patient tier: decay floor up to 300 bps
                curatorFeeBps: 10,
                name: "RWA Outlets Patient Tier",
                symbol: "roPAT"
            })
        );

        // ---- wiring
        oracle.setNav(address(tbill), NAV_TBILL);
        oracle.setNav(address(credit), NAV_CREDIT);
        router.setQueue(address(tbill), tbillQueue);
        router.setQueue(address(credit), creditQueue);
        expressVault.addMandateAsset(address(tbill), tbillQueue, 500_000e6);
        patientVault.addMandateAsset(address(credit), creditQueue, 150_000e6);

        // ---- demo funding: KYC pass + balances for the deployer to seed pools/demos
        kyc.mint(deployer);
        usdc.mint(deployer, 2_000_000e6);
        tbill.mint(deployer, 1_000_000e18);
        credit.mint(deployer, 1_000_000e18);

        vm.stopBroadcast();

        // ---- deployments/<chainid>.json
        string memory o = "deploy";
        vm.serializeAddress(o, "Aqua", address(aqua));
        vm.serializeAddress(o, "AquaSwapVMRouter", address(swapVM));
        vm.serializeAddress(o, "NavOracle", address(oracle));
        vm.serializeAddress(o, "NavExtruction", address(navX));
        vm.serializeAddress(o, "ComplianceNFT", address(kyc));
        vm.serializeAddress(o, "TestUSDC", address(usdc));
        vm.serializeAddress(o, "rwaTBILL", address(tbill));
        vm.serializeAddress(o, "rwaCREDIT", address(credit));
        vm.serializeAddress(o, "RedemptionQueue_rwaTBILL", address(tbillQueue));
        vm.serializeAddress(o, "RedemptionQueue_rwaCREDIT", address(creditQueue));
        vm.serializeAddress(o, "OutletRouter", address(router));
        vm.serializeAddress(o, "CuratorVault_Express", address(expressVault));
        vm.serializeAddress(o, "CuratorVault_Patient", address(patientVault));
        vm.serializeAddress(o, "RWAGateHook", address(0)); // filled by DeployHook.s.sol
        string memory json = vm.serializeAddress(o, "deployer", deployer);
        vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {NavOracle} from "../src/NavOracle.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {CuratorVault} from "../src/CuratorVault.sol";

/// @notice Redeploys the two RedemptionQueues (contract updated: `RolesSet` event) and rewires
///         the existing router + tier vaults to them. Everything else — router, vaults, hook,
///         oracle, tokens — keeps its address; queues are referenced only through the mutable
///         `setQueue` / `addMandateAsset` mappings.
contract UpgradeQueues is Script {
    uint256 constant WINDOW_TBILL = 60; // compressed T+7
    uint256 constant WINDOW_CREDIT = 90; // compressed T+90
    uint16 constant QUEUE_FEE_BPS = 5;

    function run() external {
        string memory path =
            string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address usdc = vm.parseJsonAddress(json, ".TestUSDC");
        address tbill = vm.parseJsonAddress(json, ".rwaTBILL");
        address credit = vm.parseJsonAddress(json, ".rwaCREDIT");
        OutletRouter router = OutletRouter(vm.parseJsonAddress(json, ".OutletRouter"));
        CuratorVault expressVault =
            CuratorVault(vm.parseJsonAddress(json, ".CuratorVault_Express"));
        CuratorVault patientVault =
            CuratorVault(vm.parseJsonAddress(json, ".CuratorVault_Patient"));

        vm.startBroadcast();
        address deployer = msg.sender;

        RedemptionQueue tbillQueue = new RedemptionQueue(
            IERC20(tbill), IERC20(usdc), deployer, deployer, deployer,
            QUEUE_FEE_BPS, WINDOW_TBILL
        );
        RedemptionQueue creditQueue = new RedemptionQueue(
            IERC20(credit), IERC20(usdc), deployer, deployer, deployer,
            QUEUE_FEE_BPS, WINDOW_CREDIT
        );

        router.setQueue(tbill, tbillQueue);
        router.setQueue(credit, creditQueue);
        // re-registering the mandate asset swaps the vault's queue pointer + approval
        expressVault.addMandateAsset(tbill, tbillQueue, 500_000e6);
        patientVault.addMandateAsset(credit, creditQueue, 150_000e6);

        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(tbillQueue)), path, ".RedemptionQueue_rwaTBILL");
        vm.writeJson(vm.toString(address(creditQueue)), path, ".RedemptionQueue_rwaCREDIT");
    }
}

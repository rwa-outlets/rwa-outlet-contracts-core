// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {NavOracle} from "../src/NavOracle.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";

/// @notice Redeploys OutletRouter (contract updated: Uniswap v4 fallback venue —
///         `setV4Venue`, `quoteInstantAll`/`quoteBuyAll`) and records it in the deployments
///         json. State migration (queue pointers + strategy listings) runs SEPARATELY via
///         MigrateRouterState.s.sol with `OLD_ROUTER=<previous>` — it cannot live here
///         because a forge dry-run executes `vm.writeJson` too, after which the json already
///         points at the predicted new address and any in-script "read from old" logic would
///         silently read the empty new router instead.
///
///         Note: CuratorVault.ROUTER is immutable, so pools the vaults create AFTER this
///         upgrade auto-register on the old router; copy them over with the permissionless
///         `registerStrategy`. TWAP guards are not migrated — SetupV4Pool.s.sol sets them
///         fresh against the v4 pools.
///
///         Order: UpgradeRouter → MigrateRouterState (OLD_ROUTER env) → SetupV4Pool.
contract UpgradeRouter is Script {
    function run() external {
        string memory path =
            string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        ISwapVM swapVM = ISwapVM(vm.parseJsonAddress(json, ".AquaSwapVMRouter"));
        IERC20 usdc = IERC20(vm.parseJsonAddress(json, ".TestUSDC"));
        NavOracle oracle = NavOracle(vm.parseJsonAddress(json, ".NavOracle"));

        vm.startBroadcast();
        OutletRouter router = new OutletRouter(swapVM, usdc, oracle);
        vm.stopBroadcast();

        vm.writeJson(vm.toString(address(router)), path, ".OutletRouter");
    }
}

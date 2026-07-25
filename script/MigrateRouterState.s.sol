// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";

import {OutletRouter} from "../src/OutletRouter.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";

/// @notice Copies per-asset queue pointers and strategy listings from OLD_ROUTER (env) into
///         the router recorded in deployments/<chainid>.json. Split out of UpgradeRouter.s.sol
///         because a forge dry-run executes `vm.writeJson` too — after a simulate-only run the
///         json already points at the (predicted) new router, so the old address must come in
///         via env, never the json.
contract MigrateRouterState is Script {
    function run() external {
        string memory path =
            string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        OutletRouter oldRouter = OutletRouter(vm.envAddress("OLD_ROUTER"));
        OutletRouter newRouter = OutletRouter(vm.parseJsonAddress(json, ".OutletRouter"));
        require(address(oldRouter) != address(newRouter), "old == new");

        address[2] memory assets =
            [vm.parseJsonAddress(json, ".rwaTBILL"), vm.parseJsonAddress(json, ".rwaCREDIT")];

        vm.startBroadcast();
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];

            RedemptionQueue queue = oldRouter.queueOf(asset);
            if (address(queue) != address(0) && address(newRouter.queueOf(asset)) == address(0))
            {
                newRouter.setQueue(asset, queue);
            }

            bytes32[] memory listings = oldRouter.listingsOf(asset);
            for (uint256 j = 0; j < listings.length; j++) {
                if (newRouter.orderBlobOf(listings[j]).length != 0) continue; // already listed
                ISwapVM.Order memory order =
                    abi.decode(oldRouter.orderBlobOf(listings[j]), (ISwapVM.Order));
                bytes32 orderHash = newRouter.registerStrategy(asset, order);
                require(orderHash == listings[j], "listing hash drift");
            }
        }
        vm.stopBroadcast();
    }
}

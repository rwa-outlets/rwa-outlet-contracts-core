// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../lib/v4-periphery/test/shared/HookMiner.sol";

import {RWAGateHook, IBalanceOf} from "../src/RWAGateHook.sol";

/// @notice Deploys RWAGateHook to a CREATE2-mined address whose bottom bits encode the
///         beforeAddLiquidity + beforeSwap + afterSwap permissions (v4 requirement). Runs in
///         the solc 0.8.26 unit, separate from Deploy.s.sol; reads the sibling addresses from
///         deployments/<chainid>.json written by Deploy.s.sol and records itself there.
contract DeployHook is Script {
    /// @dev Canonical CREATE2 deployer proxy used by forge scripts for salted deploys.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @dev Canonical Uniswap v4 PoolManager on Ethereum Sepolia.
    address constant POOL_MANAGER_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    function run() external {
        string memory path =
            string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address kyc = vm.parseJsonAddress(json, ".ComplianceNFT");
        address usdc = vm.parseJsonAddress(json, ".TestUSDC");

        uint160 flags = uint160(
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        (address expected, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(RWAGateHook).creationCode,
            abi.encode(POOL_MANAGER_SEPOLIA, kyc, usdc)
        );

        vm.startBroadcast();
        RWAGateHook hook = new RWAGateHook{salt: salt}(
            IPoolManager(POOL_MANAGER_SEPOLIA), IBalanceOf(kyc), usdc
        );
        vm.stopBroadcast();
        require(address(hook) == expected, "hook address mismatch");

        vm.writeJson(vm.toString(address(hook)), path, ".RWAGateHook");
    }
}

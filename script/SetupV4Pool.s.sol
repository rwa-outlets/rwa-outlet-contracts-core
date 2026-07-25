// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {V4Venue} from "../src/V4Venue.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

interface IApprovable {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface INavOracleMin {
    function navOf(address asset) external view returns (uint256 nav1e18, uint40 updatedAt);
}

/// @dev ABI-level view of the 0.8.30-unit OutletRouter (swap-vm pins solc, so no import).
interface IOutletRouterAdmin {
    function setV4Venue(address venue) external;
    function setGuard(address asset, address source, bytes32 poolId, uint32 window, uint16 bandBps)
        external;
}

/// @notice Uniswap v4 lane setup (docs/02-engine-spec.md §6), solc 0.8.26 unit. Run AFTER
///         Deploy.s.sol + DeployHook.s.sol: reads deployments/<chainid>.json, deploys the
///         official V4Quoter (redeploy, never reimplemented) + our V4Venue + a demo LP
///         router, initializes both RWA/USDC pools at live NAV with the RWAGateHook attached,
///         seeds full-range demo liquidity, registers the pools on the venue, and wires the
///         OutletRouter (fallback venue + TWAP guard). Writes deployments/<chainid>.v4.json.
contract SetupV4Pool is Script {
    /// @dev Canonical Uniswap v4 PoolManager on Ethereum Sepolia (matches DeployHook.s.sol).
    address constant POOL_MANAGER_SEPOLIA = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant FULL_RANGE_LOWER = -887220;
    int24 constant FULL_RANGE_UPPER = 887220;
    int256 constant DEMO_LIQUIDITY = 5e17; // ≈ 490k RWA + 510k USDC per pool at NAV ≈ 1
    uint32 constant GUARD_WINDOW = 900; // 15 min TWAP
    uint16 constant GUARD_BAND_BPS = 100; // 1%

    IPoolManager internal manager = IPoolManager(POOL_MANAGER_SEPOLIA);

    function run() external {
        string memory path = string.concat("./deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);
        address hook = vm.parseJsonAddress(json, ".RWAGateHook");
        address usdc = vm.parseJsonAddress(json, ".TestUSDC");
        address tbill = vm.parseJsonAddress(json, ".rwaTBILL");
        address credit = vm.parseJsonAddress(json, ".rwaCREDIT");
        address router = vm.parseJsonAddress(json, ".OutletRouter");
        INavOracleMin oracle = INavOracleMin(vm.parseJsonAddress(json, ".NavOracle"));

        vm.startBroadcast();
        address deployer = msg.sender;

        V4Quoter quoter = new V4Quoter(manager);
        V4Venue venue = new V4Venue(manager, IV4Quoter(address(quoter)), usdc);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);

        IApprovable(usdc).approve(address(lpRouter), type(uint256).max);
        IApprovable(tbill).approve(address(lpRouter), type(uint256).max);
        IApprovable(credit).approve(address(lpRouter), type(uint256).max);

        bytes32 tbillPoolId = _setupPool(venue, lpRouter, oracle, hook, usdc, tbill, deployer);
        bytes32 creditPoolId = _setupPool(venue, lpRouter, oracle, hook, usdc, credit, deployer);

        IOutletRouterAdmin(router).setV4Venue(address(venue));
        IOutletRouterAdmin(router).setGuard(tbill, hook, tbillPoolId, GUARD_WINDOW, GUARD_BAND_BPS);
        IOutletRouterAdmin(router).setGuard(
            credit, hook, creditPoolId, GUARD_WINDOW, GUARD_BAND_BPS
        );

        vm.stopBroadcast();

        string memory o = "v4";
        vm.serializeAddress(o, "V4Quoter", address(quoter));
        vm.serializeAddress(o, "V4Venue", address(venue));
        vm.serializeAddress(o, "V4LpRouter", address(lpRouter));
        vm.serializeBytes32(o, "PoolId_rwaTBILL", tbillPoolId);
        string memory out = vm.serializeBytes32(o, "PoolId_rwaCREDIT", creditPoolId);
        vm.writeJson(
            out, string.concat("./deployments/", vm.toString(block.chainid), ".v4.json")
        );
    }

    function _setupPool(
        V4Venue venue,
        PoolModifyLiquidityTest lpRouter,
        INavOracleMin oracle,
        address hook,
        address usdc,
        address asset,
        address deployer
    ) internal returns (bytes32 rawPoolId) {
        (uint256 nav,) = oracle.navOf(asset);

        (Currency c0, Currency c1) = asset < usdc
            ? (Currency.wrap(asset), Currency.wrap(usdc))
            : (Currency.wrap(usdc), Currency.wrap(asset));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });

        // idempotent: a re-run against an already-initialized pool just adds liquidity
        try manager.initialize(key, _sqrtPriceForNav(usdc, key, nav)) {} catch {}

        // fresh demo balances for the LP position (tokens are deployer-mintable on testnet)
        IMintable(asset).mint(deployer, 600_000e18);
        IMintable(usdc).mint(deployer, 600_000e6);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: FULL_RANGE_LOWER,
                tickUpper: FULL_RANGE_UPPER,
                liquidityDelta: DEMO_LIQUIDITY,
                salt: 0
            }),
            abi.encodePacked(deployer) // RWAGateHook compliance: deployer holds the KYC NFT
        );

        rawPoolId = venue.registerPool(asset, FEE, TICK_SPACING, hook);
        require(rawPoolId == PoolId.unwrap(key.toId()), "poolId mismatch");
    }

    /// @dev sqrtPriceX96 matching USDC-per-RWA = nav for whichever token ordering applies
    ///      (RWA 18 decimals, USDC 6, nav 1e18) — same math as the RWAGateHook tests.
    function _sqrtPriceForNav(address usdc, PoolKey memory key, uint256 nav)
        internal
        pure
        returns (uint160)
    {
        // raw token1-per-token0 price in base units, as a 2^192-scaled square:
        //   RWA is token0 → raw = nav × 10^(6−18) / 1e18        = nav / 1e30
        //   USDC is token0 → raw = (1/nav) × 10^(18−6) × 1e18   = 1e30 / nav
        uint256 rawX192 = Currency.unwrap(key.currency1) == usdc
            ? Math.mulDiv(nav, 1 << 192, 1e30)
            : Math.mulDiv(1e30, 1 << 192, nav);
        return uint160(Math.sqrt(rawX192));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {V4Venue} from "../src/V4Venue.sol";
import {RWAGateHook, IBalanceOf} from "../src/RWAGateHook.sol";
import {ComplianceNFT} from "../src/ComplianceNFT.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {RWAToken} from "../src/RWAToken.sol";

/// @notice V4Venue against the REAL v4 stack (PoolManager + V4Quoter + RWAGateHook):
///         quote == swap, both directions, compliance propagation, registration guards.
contract V4VenueTest is Test {
    uint256 internal constant NAV = 1.0432e18;

    PoolManager internal manager;
    PoolModifyLiquidityTest internal lpRouter;
    V4Quoter internal quoter;
    V4Venue internal venue;
    ComplianceNFT internal kyc;
    TestUSDC internal usdc;
    RWAToken internal rwa;
    RWAGateHook internal hook;

    PoolKey internal key;
    bytes32 internal poolId;

    address internal user = makeAddr("user");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        manager = new PoolManager(address(this));
        lpRouter = new PoolModifyLiquidityTest(manager);
        quoter = new V4Quoter(manager);
        kyc = new ComplianceNFT();
        usdc = new TestUSDC();
        rwa = new RWAToken("Tokenized Private Credit", "rwaCREDIT", IERC721(address(kyc)));
        venue = new V4Venue(manager, IV4Quoter(address(quoter)), address(usdc));

        address hookAddr = address(
            uint160(0x1000) << 144
                | uint160(
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                )
        );
        deployCodeTo(
            "RWAGateHook.sol:RWAGateHook",
            abi.encode(manager, IBalanceOf(address(kyc)), address(usdc)),
            hookAddr
        );
        hook = RWAGateHook(hookAddr);

        (Currency c0, Currency c1) = address(usdc) < address(rwa)
            ? (Currency.wrap(address(usdc)), Currency.wrap(address(rwa)))
            : (Currency.wrap(address(rwa)), Currency.wrap(address(usdc)));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        poolId = PoolId.unwrap(key.toId());
        manager.initialize(key, _sqrtPriceForNav());

        // demo-scale full-range liquidity provided by this (KYC'd via hookData=user) contract
        usdc.mint(address(this), 100_000_000e6);
        rwa.mint(address(this), 1e27);
        usdc.approve(address(lpRouter), type(uint256).max);
        rwa.approve(address(lpRouter), type(uint256).max);
        kyc.mint(user);
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -887220,
                tickUpper: 887220,
                liquidityDelta: 5e18,
                salt: 0
            }),
            abi.encodePacked(user)
        );

        // taker balances + approvals
        usdc.mint(user, 1_000_000e6);
        rwa.mint(user, 1_000_000e18);
        vm.startPrank(user);
        usdc.approve(address(venue), type(uint256).max);
        rwa.approve(address(venue), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev sqrtPriceX96 matching USDC-per-RWA = NAV for whichever token ordering applies.
    function _sqrtPriceForNav() internal view returns (uint160) {
        uint256 rawX192;
        if (Currency.unwrap(key.currency1) == address(usdc)) {
            rawX192 = Math.mulDiv(NAV, 1 << 192, 1e30);
        } else {
            rawX192 = Math.mulDiv(1e30, 1 << 192, NAV);
        }
        return uint160(Math.sqrt(rawX192));
    }

    // ------------------------------------------------------------ registration

    function test_RegisterPool_setsPoolId() public {
        bytes32 id = venue.registerPool(address(rwa), 3000, 60, address(hook));
        assertEq(id, poolId, "poolId matches PoolKey");
        assertEq(venue.poolIdOf(address(rwa)), poolId);
    }

    function test_RegisterPool_revertsWhenUninitialized() public {
        RWAToken other = new RWAToken("Other", "OTH", IERC721(address(kyc)));
        vm.expectRevert(); // PoolNotInitialized
        venue.registerPool(address(other), 3000, 60, address(hook));
    }

    function test_RegisterPool_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger)
        );
        venue.registerPool(address(rwa), 3000, 60, address(hook));
    }

    function test_UnregisteredAssetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(V4Venue.PoolNotRegistered.selector, address(rwa)));
        venue.quoteExactIn(address(rwa), true, 1e18, user);
    }

    // ---------------------------------------------------------- quote == swap

    function test_ExitQuoteMatchesSwap() public {
        venue.registerPool(address(rwa), 3000, 60, address(hook));
        uint256 amountIn = 1_000e18;

        uint256 quoted = venue.quoteExactIn(address(rwa), true, amountIn, user);
        assertApproxEqRel(quoted, (amountIn * NAV) / 1e30, 0.02e18, "quote near NAV");

        uint256 usdcBefore = usdc.balanceOf(user);
        vm.prank(user);
        uint256 out = venue.swapExactIn(address(rwa), true, amountIn, quoted, user, user);

        assertEq(out, quoted, "quote == swap");
        assertEq(usdc.balanceOf(user), usdcBefore + out, "USDC straight to user");
        assertEq(usdc.balanceOf(address(venue)), 0, "venue holds nothing");
        assertEq(rwa.balanceOf(address(venue)), 0, "venue holds nothing");
        assertEq(hook.observationCount(poolId), 1, "hook recorded the fill");
    }

    function test_BuyQuoteMatchesSwap() public {
        venue.registerPool(address(rwa), 3000, 60, address(hook));
        uint256 usdcIn = 1_000e6;

        uint256 quoted = venue.quoteExactIn(address(rwa), false, usdcIn, user);
        assertApproxEqRel(quoted, (uint256(usdcIn) * 1e30) / NAV, 0.02e18, "quote near 1/NAV");

        uint256 rwaBefore = rwa.balanceOf(user);
        vm.prank(user);
        uint256 out = venue.swapExactIn(address(rwa), false, usdcIn, quoted, user, user);

        assertEq(out, quoted, "quote == swap");
        assertEq(rwa.balanceOf(user), rwaBefore + out, "RWA straight to user");
        assertEq(usdc.balanceOf(address(venue)), 0);
    }

    // ------------------------------------------------------------- protections

    function test_MinOutReverts() public {
        venue.registerPool(address(rwa), 3000, 60, address(hook));
        uint256 quoted = venue.quoteExactIn(address(rwa), true, 100e18, user);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(V4Venue.InsufficientOutput.selector, quoted, quoted + 1)
        );
        venue.swapExactIn(address(rwa), true, 100e18, quoted + 1, user, user);
    }

    function test_NonCompliantUserBlocked() public {
        venue.registerPool(address(rwa), 3000, 60, address(hook));

        vm.expectRevert(); // RWAGateHook.NotCompliant wrapped by the manager
        venue.quoteExactIn(address(rwa), true, 100e18, stranger);

        rwa.mint(stranger, 100e18);
        vm.startPrank(stranger);
        rwa.approve(address(venue), type(uint256).max);
        vm.expectRevert();
        venue.swapExactIn(address(rwa), true, 100e18, 0, stranger, stranger);
        vm.stopPrank();
    }

    function test_OnlyPoolManagerCallback() public {
        vm.expectRevert(V4Venue.NotPoolManager.selector);
        venue.unlockCallback("");
    }
}

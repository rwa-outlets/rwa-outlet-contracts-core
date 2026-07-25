// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Aqua} from "@1inch/aqua/src/Aqua.sol";
import {AquaSwapVMRouter} from "swap-vm/src/routers/AquaSwapVMRouter.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "swap-vm/src/libs/MakerTraits.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {NavOracle} from "../../src/NavOracle.sol";
import {NavExtruction} from "../../src/NavExtruction.sol";
import {ComplianceNFT} from "../../src/ComplianceNFT.sol";
import {TestUSDC} from "../../src/TestUSDC.sol";
import {RWAToken} from "../../src/RWAToken.sol";

/// @notice Shared harness: deploys the OFFICIAL Aqua + AquaSwapVMRouter from the vendored
///         1inch sources (never reimplemented) plus our outlet contracts. The test contract
///         itself acts as the taker unless noted.
abstract contract OutletTestBase is Test {
    uint256 internal constant NAV = 1.0432e18; // rwaCREDIT-style demo NAV
    uint256 internal constant RWA_SCALE = 1e30; // 10^(18 + 18 − 6)

    Aqua internal aqua;
    AquaSwapVMRouter internal swapVM;
    NavOracle internal oracle;
    NavExtruction internal navX;
    ComplianceNFT internal kyc;
    TestUSDC internal usdc;
    RWAToken internal rwa;

    address internal maker = makeAddr("maker");

    function setUp() public virtual {
        aqua = new Aqua();
        swapVM = new AquaSwapVMRouter(address(aqua), address(0), address(this), "AquaSwapVM", "1.0.0");
        oracle = new NavOracle();
        navX = new NavExtruction(oracle);
        kyc = new ComplianceNFT();
        usdc = new TestUSDC();
        rwa = new RWAToken("Tokenized Private Credit", "rwaCREDIT", IERC721(address(kyc)));

        oracle.setNav(address(rwa), NAV);

        // maker capital + Aqua approvals
        usdc.mint(maker, 10_000_000e6);
        rwa.mint(maker, 10_000_000e18);
        vm.startPrank(maker);
        usdc.approve(address(aqua), type(uint256).max);
        rwa.approve(address(aqua), type(uint256).max);
        vm.stopPrank();

        // taker-side approvals (this test contract takes via useTransferFromAndAquaPush)
        usdc.approve(address(swapVM), type(uint256).max);
        rwa.approve(address(swapVM), type(uint256).max);
    }

    // ------------------------------------------------------------- builders

    function buildOrder(address maker_, bytes memory program)
        internal
        pure
        returns (ISwapVM.Order memory)
    {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker_,
                receiver: address(0),
                shouldUnwrapWeth: false,
                useAquaInsteadOfSignature: true,
                allowZeroAmountIn: false,
                hasPreTransferInHook: false,
                hasPostTransferInHook: false,
                hasPreTransferOutHook: false,
                hasPostTransferOutHook: false,
                preTransferInTarget: address(0),
                preTransferInData: "",
                postTransferInTarget: address(0),
                postTransferInData: "",
                preTransferOutTarget: address(0),
                preTransferOutData: "",
                postTransferOutTarget: address(0),
                postTransferOutData: "",
                program: program
            })
        );
    }

    /// @dev Ships `abi.encode(order)` to the official Aqua registry with USDC/RWA balances.
    function ship(ISwapVM.Order memory order, uint256 usdcAmount, uint256 rwaAmount)
        internal
        returns (bytes32 strategyHash)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(rwa);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = rwaAmount;

        vm.prank(order.maker);
        strategyHash = aqua.ship(address(swapVM), abi.encode(order), tokens, amounts);
        assertEq(strategyHash, swapVM.hash(order), "strategyHash == orderHash");
    }

    function takerData(bool isExactIn, uint256 threshold) internal view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: isExactIn,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: true,
                useTransferFromAndAquaPush: true,
                threshold: threshold == 0 ? bytes("") : abi.encodePacked(threshold),
                to: address(0),
                deadline: 0,
                hasPreTransferInCallback: false,
                hasPreTransferOutCallback: false,
                preTransferInHookData: "",
                postTransferInHookData: "",
                preTransferOutHookData: "",
                postTransferOutHookData: "",
                preTransferInCallbackData: "",
                preTransferOutCallbackData: "",
                instructionsArgs: "",
                signature: ""
            })
        );
    }

    function quote(ISwapVM.Order memory order, address tokenIn, address tokenOut, uint256 amount, bool isExactIn)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut,) =
            swapVM.asView().quote(order, tokenIn, tokenOut, amount, takerData(isExactIn, 0));
    }

    function swap(ISwapVM.Order memory order, address tokenIn, address tokenOut, uint256 amount, bool isExactIn)
        internal
        returns (uint256 amountIn, uint256 amountOut)
    {
        (amountIn, amountOut,) =
            swapVM.swap(order, tokenIn, tokenOut, amount, takerData(isExactIn, 0));
    }

    function aquaBalances(bytes32 strategyHash, address maker_)
        internal
        view
        returns (uint256 usdcBal, uint256 rwaBal)
    {
        return aqua.safeBalances(maker_, address(swapVM), strategyHash, address(usdc), address(rwa));
    }
}

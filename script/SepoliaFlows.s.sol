// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "swap-vm/src/libs/MakerTraits.sol";

import {NavOracle} from "../src/NavOracle.sol";
import {RedemptionQueue} from "../src/RedemptionQueue.sol";
import {OutletRouter} from "../src/OutletRouter.sol";
import {CuratorVault} from "../src/CuratorVault.sol";
import {OutletPrograms} from "../src/libraries/OutletPrograms.sol";

interface IFaucet {
    function drip() external;
    function nextClaimAt(address to) external view returns (uint256);
}

/// @notice Live user-flow suite for the Sepolia deployment. Each external function is one
///         flow step, run by ONE actor via `--sig` + that actor's mnemonic (see
///         script/run-sepolia-flows.sh for the orchestration and actor mapping):
///
///         deployer (MNEMONIC)  — curator, issuer, oracle keeper on every contract
///         LP       (MNEMONIC1) — vault deposit / async exit
///         trader   (MNEMONIC2) — instant exits + Market-pool buy through the router
///         patient  (MNEMONIC3) — direct queue redemption + operator auto-claim
///         maker    (MNEMONIC4) — pro (B2B) maker shipping own-wallet strategies
contract SepoliaFlows is Script {
    IAqua aqua;
    ISwapVM swapVM;
    NavOracle oracle;
    address navX;
    IFaucet faucet;
    IERC20 usdc;
    IERC20 tbill;
    IERC20 credit;
    RedemptionQueue tbillQueue;
    RedemptionQueue creditQueue;
    OutletRouter router;
    CuratorVault expressVault;
    CuratorVault patientVault;

    uint256 constant NAV_TBILL = 1.0021e18;
    uint256 constant NAV_CREDIT = 1.0432e18;
    uint256 constant RWA_SCALE = 1e30; // 10^(18 + 18 - 6)

    function _load() internal {
        string memory json =
            vm.readFile(string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        aqua = IAqua(vm.parseJsonAddress(json, ".Aqua"));
        swapVM = ISwapVM(vm.parseJsonAddress(json, ".AquaSwapVMRouter"));
        oracle = NavOracle(vm.parseJsonAddress(json, ".NavOracle"));
        navX = vm.parseJsonAddress(json, ".NavExtruction");
        faucet = IFaucet(vm.parseJsonAddress(json, ".Faucet"));
        usdc = IERC20(vm.parseJsonAddress(json, ".TestUSDC"));
        tbill = IERC20(vm.parseJsonAddress(json, ".rwaTBILL"));
        credit = IERC20(vm.parseJsonAddress(json, ".rwaCREDIT"));
        tbillQueue = RedemptionQueue(vm.parseJsonAddress(json, ".RedemptionQueue_rwaTBILL"));
        creditQueue = RedemptionQueue(vm.parseJsonAddress(json, ".RedemptionQueue_rwaCREDIT"));
        router = OutletRouter(vm.parseJsonAddress(json, ".OutletRouter"));
        expressVault = CuratorVault(vm.parseJsonAddress(json, ".CuratorVault_Express"));
        patientVault = CuratorVault(vm.parseJsonAddress(json, ".CuratorVault_Patient"));
    }

    // ---------------------------------------------------- step 1: any actor

    /// @notice Faucet drip: demo tokens + KYC pass (+ gas stipend). Skips inside cooldown.
    function drip() external {
        _load();
        address me = msg.sender;
        vm.startBroadcast();
        if (block.timestamp >= faucet.nextClaimAt(me)) {
            faucet.drip();
        } else {
            console2.log("cooldown active, skipping drip");
        }
        vm.stopBroadcast();
        console2.log("USDC ", usdc.balanceOf(me));
        console2.log("TBILL", tbill.balanceOf(me));
        console2.log("CRED ", credit.balanceOf(me));
    }

    // ----------------------------------------------------------- step 2: LP

    /// @notice B2C entry: sync ERC-4626 deposits into both tier vaults.
    function lpDeposit() external {
        _load();
        address me = msg.sender;
        vm.startBroadcast();
        usdc.approve(address(expressVault), type(uint256).max);
        usdc.approve(address(patientVault), type(uint256).max);
        uint256 sharesE = expressVault.deposit(500e6, me);
        uint256 sharesP = patientVault.deposit(250e6, me);
        vm.stopBroadcast();
        console2.log("roEXP shares", sharesE);
        console2.log("roPAT shares", sharesP);
    }

    // ------------------------------------------------ step 3: curator agent

    /// @notice Curator refreshes NAVs and ships the Express + Patient pools from LP capital
    ///         (the vault is the Aqua contract maker).
    function curatorPools() external {
        _load();
        vm.startBroadcast();
        oracle.setNav(address(tbill), NAV_TBILL);
        oracle.setNav(address(credit), NAV_CREDIT);
        bytes32 pe = expressVault.createPool(
            address(tbill),
            CuratorVault.PoolKind.Express,
            abi.encode(uint16(15), uint32(24 hours), uint256(300e6), uint256(0))
        );
        bytes32 pp = patientVault.createPool(
            address(credit),
            CuratorVault.PoolKind.Patient,
            abi.encode(
                uint16(30), // startBps
                uint16(300), // floorBps (== mandate max)
                uint40(block.timestamp),
                uint32(7200), // 2h decay
                uint32(24 hours),
                uint256(150e6)
            )
        );
        vm.stopBroadcast();
        console2.log("express pool", vm.toString(pe));
        console2.log("patient pool", vm.toString(pp));
    }

    // --------------------------------------------------- step 4: pro maker

    /// @notice B2B maker: ships a two-sided Market (xyc) pool and an isolated resting bid
    ///         from their own wallet, then lists both on the router.
    function proMakerShip() external {
        _load();
        address me = msg.sender;
        (uint256 navC,) = oracle.navOf(address(credit));

        // Market pool: reserves at the NAV ratio so fills sit inside the 5% NAV band
        uint256 rwaAmt = 300e18;
        uint256 usdcAmt = (rwaAmt * navC) / RWA_SCALE; // ~312.96 USDC
        bytes memory marketProg = OutletPrograms.marketProgram(
            navX, 3, address(credit), address(usdc), 500, 24 hours, address(0),
            uint64(block.timestamp)
        );
        ISwapVM.Order memory marketOrder = _order(me, marketProg);

        // Resting bid: fixed 50 bps spread + hard deadline, ring-fenced funding
        bytes memory bidProg = bytes.concat(
            OutletPrograms.deadlineInstr(uint40(block.timestamp + 2 hours)),
            OutletPrograms.extructionInstr(
                navX,
                OutletPrograms.fixedSpreadArgs(1, address(credit), address(usdc), 50, 24 hours)
            ),
            OutletPrograms.saltInstr(uint64(block.timestamp + 1))
        );
        ISwapVM.Order memory bidOrder = _order(me, bidProg);

        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(credit);
        uint256[] memory marketAmts = new uint256[](2);
        marketAmts[0] = usdcAmt;
        marketAmts[1] = rwaAmt;
        uint256[] memory bidAmts = new uint256[](2);
        bidAmts[0] = 100e6;
        bidAmts[1] = 100e18; // small RWA side so entry-direction fills are also backed

        vm.startBroadcast();
        usdc.approve(address(aqua), type(uint256).max);
        credit.approve(address(aqua), type(uint256).max);
        bytes32 marketHash =
            aqua.ship(address(swapVM), abi.encode(marketOrder), tokens, marketAmts);
        bytes32 bidHash = aqua.ship(address(swapVM), abi.encode(bidOrder), tokens, bidAmts);
        router.registerStrategy(address(credit), marketOrder);
        router.registerStrategy(address(credit), bidOrder);
        vm.stopBroadcast();
        console2.log("market strategy", vm.toString(marketHash));
        console2.log("resting bid    ", vm.toString(bidHash));
    }

    // ------------------------------------------------------ step 5: trader

    /// @notice Impatient exits (Pool 1 fixed spread, Pool 2 decay auction / resting bid) and
    ///         a Market-pool entry, all best-of routed.
    function traderSwaps() external {
        _load();
        address me = msg.sender;

        (bytes32 h1, uint256 q1) = router.quoteInstant(address(tbill), 200e18);
        require(h1 != bytes32(0), "no tbill quote");
        (bytes32 h2, uint256 q2) = router.quoteInstant(address(credit), 50e18);
        require(h2 != bytes32(0), "no credit quote");
        (bytes32 h3, uint256 q3) = router.quoteBuy(address(credit), 20e6);
        require(h3 != bytes32(0), "no buy quote");

        vm.startBroadcast();
        tbill.approve(address(router), type(uint256).max);
        credit.approve(address(router), type(uint256).max);
        usdc.approve(address(router), type(uint256).max);
        uint256 out1 = router.redeemInstant(address(tbill), 200e18, (q1 * 97) / 100);
        uint256 out2 = router.redeemInstant(address(credit), 50e18, (q2 * 97) / 100);
        uint256 out3 = router.buy(address(credit), 20e6, (q3 * 97) / 100);
        vm.stopBroadcast();
        console2.log("sold 200 TBILL for USDC", out1);
        console2.log("sold 50 CRED for USDC  ", out2);
        console2.log("bought CRED with 20 USDC", out3);
        console2.log("USDC after", usdc.balanceOf(me));
    }

    // ----------------------------------------------- step 6: patient holder

    /// @notice Patient exit: ERC-7540 request straight into the queue, plus operator approval
    ///         so the curator agent can auto-claim at settlement.
    function patientRequest() external {
        _load();
        address me = msg.sender;
        address operator = vm.envAddress("DEPLOYER_ADDR");
        vm.startBroadcast();
        credit.approve(address(creditQueue), type(uint256).max);
        uint256 epoch = creditQueue.requestRedeem(500e18, me, me);
        creditQueue.setOperator(operator, true);
        vm.stopBroadcast();
        console2.log("queued 500 CRED in epoch", epoch);
        console2.log("pending", creditQueue.pendingRedeemRequest(epoch, me));
    }

    // --------------------------------------------- step 7: curator (agent)

    /// @notice NAV-capture loop: recycles the RWA inventory the vaults bought from the trader
    ///         into the queues, then batches both open epochs to the issuer.
    function curatorRecycleSubmit() external {
        _load();
        uint256 invT = tbill.balanceOf(address(expressVault));
        uint256 invC = credit.balanceOf(address(patientVault));
        vm.startBroadcast();
        if (invT > 0) expressVault.recycle(address(tbill), invT);
        if (invC > 0) patientVault.recycle(address(credit), invC);
        tbillQueue.submitToIssuer(tbillQueue.currentEpoch());
        creditQueue.submitToIssuer(creditQueue.currentEpoch());
        vm.stopBroadcast();
        console2.log("recycled TBILL", invT);
        console2.log("recycled CRED ", invC);
    }

    // -------------------------------------------- step 8: issuer (deployer)
    // (run-sepolia-flows.sh sleeps out the 60s/90s issuer windows first)

    /// @notice Issuer settles both epochs at oracle NAV — pulls gross settlement USDC in,
    ///         takes the escrowed RWA out.
    function issuerSettle() external {
        _load();
        (uint256 navT,) = oracle.navOf(address(tbill));
        (uint256 navC,) = oracle.navOf(address(credit));
        vm.startBroadcast();
        usdc.approve(address(tbillQueue), type(uint256).max);
        usdc.approve(address(creditQueue), type(uint256).max);
        tbillQueue.settle(tbillQueue.lastSettledEpoch() + 1, navT);
        creditQueue.settle(creditQueue.lastSettledEpoch() + 1, navC);
        vm.stopBroadcast();
        console2.log("tbill queue cash ", usdc.balanceOf(address(tbillQueue)));
        console2.log("credit queue cash", usdc.balanceOf(address(creditQueue)));
    }

    // ------------------------------------------- step 9: curator as operator

    /// @notice Settlement claims: operator auto-claim for the patient holder, and the vaults
    ///         harvest their recycled positions (NAV minus purchase discount = profit).
    function operatorClaims() external {
        _load();
        address patient = vm.envAddress("PATIENT_ADDR");
        uint256 patientClaim = creditQueue.maxRedeem(patient);
        uint256 vaultClaimT = tbillQueue.maxRedeem(address(expressVault));
        uint256 vaultClaimC = creditQueue.maxRedeem(address(patientVault));
        vm.startBroadcast();
        if (patientClaim > 0) creditQueue.redeem(patientClaim, patient, patient);
        if (vaultClaimT > 0) expressVault.claimQueue(address(tbill), vaultClaimT);
        if (vaultClaimC > 0) patientVault.claimQueue(address(credit), vaultClaimC);
        vm.stopBroadcast();
        console2.log("auto-claimed for patient, USDC", usdc.balanceOf(patient));
        console2.log("express vault USDC", usdc.balanceOf(address(expressVault)));
        console2.log("patient vault USDC", usdc.balanceOf(address(patientVault)));
    }

    // ------------------------------------------------------- step 10-12: LP exit

    /// @notice LP async exit: request half the Express shares (ERC-7540 epoch).
    function lpExitRequest() external {
        _load();
        address me = msg.sender;
        uint256 shares = expressVault.balanceOf(me) / 2;
        vm.startBroadcast();
        uint256 epoch = expressVault.requestRedeem(shares, me, me);
        vm.stopBroadcast();
        console2.log("requested exit of shares", shares);
        console2.log("vault epoch", epoch);
    }

    /// @notice Curator fulfills the LP exit epoch at the realized share price.
    function curatorFulfill() external {
        _load();
        vm.startBroadcast();
        expressVault.fulfillRedeemEpoch(expressVault.currentEpoch());
        vm.stopBroadcast();
        console2.log("epoch fulfilled, reserved", expressVault.reservedAssets());
    }

    /// @notice LP claims the fulfilled epoch — USDC back, spreads + NAV capture included.
    function lpClaim() external {
        _load();
        address me = msg.sender;
        uint256 claimable = expressVault.maxRedeem(me);
        vm.startBroadcast();
        uint256 assets = expressVault.redeem(claimable, me, me);
        vm.stopBroadcast();
        console2.log("redeemed shares", claimable);
        console2.log("USDC received  ", assets);
        console2.log("USDC balance   ", usdc.balanceOf(me));
    }

    // ------------------------------------------------------------- helpers

    function _order(address maker, bytes memory program)
        private
        pure
        returns (ISwapVM.Order memory)
    {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: maker,
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
}

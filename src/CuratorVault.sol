// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAqua} from "@1inch/aqua/src/interfaces/IAqua.sol";
import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {MakerTraitsLib} from "swap-vm/src/libs/MakerTraits.sol";

import {NavOracle} from "./NavOracle.sol";
import {RedemptionQueue} from "./RedemptionQueue.sol";
import {OutletRouter} from "./OutletRouter.sol";
import {OutletPrograms} from "./libraries/OutletPrograms.sol";

/// @title CuratorVault — B2C capital vault per risk tier (docs/03-contracts.md §2.8)
/// @notice LPs deposit USDC only; the curator (the AI agent) operates every mandate RWA of the
///         tier by shipping pool strategies on Aqua — the vault is the maker, a *contract maker*
///         (`useAquaInsteadOfSignature`, no EOA signature). Because Aqua balances are virtual
///         allowances over this wallet, one capital base backs Express, Patient, and Market
///         pools at once.
///
///         ERC-4626 sync deposit at NAV-based share price + ERC-7540 async redemption epochs
///         (LP exits settle at realized values — no oracle-priced instant exit, which closes the
///         classic 4626 stale-price arbitrage). ERC-7575: the vault is its own share token,
///         `share() == address(this)`.
contract CuratorVault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum PoolKind {
        Express, // NavExtruction FixedSpread
        Patient, // NavExtruction DutchDecay (exit-only auction)
        Market // _xycSwapXD + NavExtruction NavBand
    }

    struct PoolInfo {
        address asset;
        PoolKind kind;
        bool active;
    }

    struct VaultEpoch {
        bool fulfilled;
        uint256 totalShares; // vault shares escrowed into this epoch
        uint256 totalAssets; // USDC owed, fixed at fulfillment
    }

    struct Config {
        IAqua aqua;
        ISwapVM swapVM; // official AquaSwapVMRouter
        IERC20 usdc;
        NavOracle navOracle;
        address navExtruction;
        OutletRouter router;
        address curator;
        address curatorTreasury;
        address complianceGate; // ComplianceNFT enforced on takers via program gate; zero = open
        uint32 navMaxStaleness;
        uint16 maxDiscountFloorBps; // mandate: deepest Patient-auction discount allowed
        uint16 curatorFeeBps; // ops fee on settled queue flow
        string name;
        string symbol;
    }

    // ---------------------------------------------------------------- state

    uint256 private constant BPS = 10_000;
    uint8 public constant EXPRESS_POOL_ID = 1;
    uint8 public constant PATIENT_POOL_ID = 2;
    uint8 public constant MARKET_POOL_ID = 3;

    IAqua public immutable AQUA;
    ISwapVM public immutable SWAP_VM;
    IERC20 public immutable USDC;
    NavOracle public immutable NAV_ORACLE;
    address public immutable NAV_EXTRUCTION;
    OutletRouter public immutable ROUTER;
    uint256 private immutable _shareScale; // shares 18d per 1 USDC unit at price 1.0

    address public curator;
    address public curatorTreasury;
    address public complianceGate;
    uint32 public navMaxStaleness;
    uint16 public maxDiscountFloorBps;
    uint16 public curatorFeeBps;

    // mandate
    address[] public mandateAssets;
    mapping(address asset => bool) public isMandateAsset;
    mapping(address asset => uint256) public perAssetCap; // max USDC shipped per asset
    mapping(address asset => RedemptionQueue) public queueOf;
    mapping(address asset => uint256) public queuedShares; // RWA in flight through the queue

    // pools
    bytes32[] public poolHashes;
    mapping(bytes32 strategyHash => PoolInfo) public pools;
    uint64 public saltNonce;

    // LP redemption epochs
    uint256 public currentEpoch = 1;
    uint256 public reservedAssets; // USDC earmarked for fulfilled, unclaimed epochs
    mapping(uint256 epoch => VaultEpoch) private _epochs;
    mapping(uint256 epoch => mapping(address controller => uint256)) public sharesAt;
    mapping(address controller => uint256[]) private _epochsOf;
    mapping(address controller => uint256) private _epochCursor;
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    // ---------------------------------------------------------------- events

    /// @dev ERC-4626 / ERC-7540 standard events
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed controller,
        uint256 assets,
        uint256 shares
    );
    /// @dev ours
    event MandateAssetAdded(address indexed asset, address queue, uint256 perAssetCap);
    event PoolCreated(
        bytes32 indexed strategyHash,
        address indexed asset,
        PoolKind kind,
        uint256 usdcShipped,
        uint256 rwaShipped,
        bytes params
    );
    event PoolDocked(bytes32 indexed strategyHash, address indexed asset);
    event Recycled(address indexed asset, uint256 shares, uint256 indexed queueEpoch);
    event QueueClaimed(address indexed asset, uint256 shares, uint256 proceeds, uint256 curatorFee);
    event EpochFulfilled(uint256 indexed epoch, uint256 shares, uint256 assets);
    event RolesSet(address curator, address curatorTreasury);

    // ---------------------------------------------------------------- errors

    error NotCurator();
    error NotAuthorized();
    error ZeroAmount();
    error AssetNotInMandate(address asset);
    error AssetCapExceeded(address asset, uint256 requested, uint256 cap);
    error DiscountBeyondMandate(uint16 floorBps, uint16 maxAllowed);
    error InsufficientFreeCash(uint256 requested, uint256 free);
    error PoolNotActive(bytes32 strategyHash);
    error EpochNotOpen(uint256 epoch);
    error ExceedsClaimable(uint256 requested, uint256 claimable);
    error AsyncFlowOnly();
    error StaleNav(address asset, uint256 updatedAt);

    modifier onlyCurator() {
        if (msg.sender != curator && msg.sender != owner()) revert NotCurator();
        _;
    }

    // ---------------------------------------------------------------- setup

    constructor(Config memory cfg) ERC20(cfg.name, cfg.symbol) Ownable(msg.sender) {
        AQUA = cfg.aqua;
        SWAP_VM = cfg.swapVM;
        USDC = cfg.usdc;
        NAV_ORACLE = cfg.navOracle;
        NAV_EXTRUCTION = cfg.navExtruction;
        ROUTER = cfg.router;
        curator = cfg.curator;
        curatorTreasury = cfg.curatorTreasury;
        complianceGate = cfg.complianceGate;
        navMaxStaleness = cfg.navMaxStaleness;
        maxDiscountFloorBps = cfg.maxDiscountFloorBps;
        curatorFeeBps = cfg.curatorFeeBps;
        _shareScale = 10 ** (18 - IERC20Metadata(address(cfg.usdc)).decimals());

        USDC.forceApprove(address(AQUA), type(uint256).max);
    }

    function setRoles(address curator_, address curatorTreasury_) external onlyOwner {
        curator = curator_;
        curatorTreasury = curatorTreasury_;
        emit RolesSet(curator_, curatorTreasury_);
    }

    /// @notice Adds an RWA to the tier mandate with its redemption queue and shipping cap.
    function addMandateAsset(address asset, RedemptionQueue queue, uint256 cap)
        external
        onlyOwner
    {
        if (!isMandateAsset[asset]) {
            isMandateAsset[asset] = true;
            mandateAssets.push(asset);
        }
        queueOf[asset] = queue;
        perAssetCap[asset] = cap;
        IERC20(asset).forceApprove(address(AQUA), type(uint256).max);
        if (address(queue) != address(0)) {
            IERC20(asset).forceApprove(address(queue), type(uint256).max);
        }
        emit MandateAssetAdded(asset, address(queue), cap);
    }

    // ------------------------------------------------------- ERC-7575 views

    /// @notice ERC-7575: the vault is its own share token.
    function share() external view returns (address) {
        return address(this);
    }

    function asset() external view returns (address) {
        return address(USDC);
    }

    /// @notice Free USDC (wallet minus LP-reserved cash) plus RWA inventory — wallet balances
    ///         and in-flight queue positions — valued at oracle NAV. Shipped Aqua balances are
    ///         *allowances over this wallet*, not additional assets, so they are not re-added.
    function totalAssets() public view returns (uint256 assets) {
        assets = USDC.balanceOf(address(this)) - reservedAssets;
        for (uint256 i = 0; i < mandateAssets.length; i++) {
            address rwa = mandateAssets[i];
            uint256 inventory = IERC20(rwa).balanceOf(address(this)) + queuedShares[rwa];
            if (inventory == 0) continue;
            (uint256 nav,) = NAV_ORACLE.navOf(rwa);
            assets += Math.mulDiv(inventory, nav, _rwaScale(rwa));
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets * _shareScale;
        return Math.mulDiv(assets, supply, totalAssets());
    }

    // ---------------------------------------------------------- LP deposit

    /// @notice Sync 4626 deposit at NAV-based share price; reverts while any held RWA's NAV is
    ///         stale so LPs can never mint against mispriced inventory.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        _requireFreshNavs();
        shares = convertToShares(assets);
        USDC.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev ERC-7540: redemption previews MUST revert (async flow).
    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    // ----------------------------------------------------- LP async redeem

    /// @notice ERC-7540 request leg: escrows vault shares into the current epoch. Exits settle
    ///         at realized values when the curator frees capital and fulfills the epoch.
    function requestRedeem(uint256 shares, address controller, address owner_)
        external
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroAmount();
        if (msg.sender != owner_ && !isOperator[owner_][msg.sender]) revert NotAuthorized();

        requestId = currentEpoch;
        _transfer(owner_, address(this), shares);

        if (sharesAt[requestId][controller] == 0) {
            _epochsOf[controller].push(requestId);
        }
        sharesAt[requestId][controller] += shares;
        _epochs[requestId].totalShares += shares;

        emit RedeemRequest(controller, owner_, requestId, msg.sender, shares);
    }

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256)
    {
        return _epochs[requestId].fulfilled ? 0 : sharesAt[requestId][controller];
    }

    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256)
    {
        return _epochs[requestId].fulfilled ? sharesAt[requestId][controller] : 0;
    }

    /// @notice Curator fulfills the open epoch at the current realized share price, reserving
    ///         free USDC for LP claims. Requires capital already freed (dock pools / claim
    ///         queues first).
    function fulfillRedeemEpoch(uint256 epoch) external onlyCurator {
        if (epoch != currentEpoch) revert EpochNotOpen(epoch);
        VaultEpoch storage e = _epochs[epoch];
        if (e.totalShares == 0) revert ZeroAmount();
        _requireFreshNavs();

        uint256 assetsOwed = Math.mulDiv(e.totalShares, totalAssets(), totalSupply());
        uint256 free = USDC.balanceOf(address(this)) - reservedAssets;
        if (assetsOwed > free) revert InsufficientFreeCash(assetsOwed, free);

        e.fulfilled = true;
        e.totalAssets = assetsOwed;
        reservedAssets += assetsOwed;
        currentEpoch = epoch + 1;
        _burn(address(this), e.totalShares);

        emit EpochFulfilled(epoch, e.totalShares, assetsOwed);
    }

    /// @notice 4626 claim leg over fulfilled epochs, FIFO, pro-rata at each epoch's realized
    ///         price.
    function redeem(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();
        if (msg.sender != controller && !isOperator[controller][msg.sender]) {
            revert NotAuthorized();
        }

        uint256 remaining = shares;
        uint256[] storage epochs = _epochsOf[controller];
        uint256 cursor = _epochCursor[controller];

        while (remaining > 0 && cursor < epochs.length) {
            uint256 ep = epochs[cursor];
            VaultEpoch storage e = _epochs[ep];
            if (!e.fulfilled) break;

            uint256 avail = sharesAt[ep][controller];
            if (avail == 0) {
                cursor++;
                continue;
            }

            uint256 take = avail < remaining ? avail : remaining;
            sharesAt[ep][controller] = avail - take;
            remaining -= take;
            assets += Math.mulDiv(take, e.totalAssets, e.totalShares);

            if (take == avail) cursor++;
        }
        _epochCursor[controller] = cursor;

        if (remaining > 0) revert ExceedsClaimable(shares, shares - remaining);

        reservedAssets -= assets;
        USDC.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    function maxRedeem(address controller) external view returns (uint256 shares) {
        uint256[] storage epochs = _epochsOf[controller];
        for (uint256 i = _epochCursor[controller]; i < epochs.length; i++) {
            if (!_epochs[epochs[i]].fulfilled) break;
            shares += sharesAt[epochs[i]][controller];
        }
    }

    // ------------------------------------------------------- curator: pools

    /// @notice Ships a pool strategy on Aqua with this vault as contract maker and lists it on
    ///         the OutletRouter. Params encoding per kind:
    ///         Express: abi.encode(spreadBps u16, maxStaleness u32, usdcAmount, rwaAmount)
    ///         Patient: abi.encode(startBps u16, floorBps u16, startTime u40, duration u32,
    ///                             maxStaleness u32, usdcAmount)
    ///         Market:  abi.encode(bandBps u16, maxStaleness u32, usdcAmount, rwaAmount)
    function createPool(address asset_, PoolKind kind, bytes calldata params)
        external
        onlyCurator
        returns (bytes32 strategyHash)
    {
        if (!isMandateAsset[asset_]) revert AssetNotInMandate(asset_);

        bytes memory program;
        uint256 usdcAmount;
        uint256 rwaAmount;

        if (kind == PoolKind.Express) {
            (uint16 spreadBps, uint32 staleness, uint256 usdcAmt, uint256 rwaAmt) =
                abi.decode(params, (uint16, uint32, uint256, uint256));
            (usdcAmount, rwaAmount) = (usdcAmt, rwaAmt);
            program = OutletPrograms.expressProgram(
                NAV_EXTRUCTION,
                EXPRESS_POOL_ID,
                asset_,
                address(USDC),
                spreadBps,
                staleness,
                complianceGate,
                ++saltNonce
            );
        } else if (kind == PoolKind.Patient) {
            (
                uint16 startBps,
                uint16 floorBps,
                uint40 startTime,
                uint32 duration,
                uint32 staleness,
                uint256 usdcAmt
            ) = abi.decode(params, (uint16, uint16, uint40, uint32, uint32, uint256));
            if (floorBps > maxDiscountFloorBps) {
                revert DiscountBeyondMandate(floorBps, maxDiscountFloorBps);
            }
            usdcAmount = usdcAmt;
            program = OutletPrograms.patientProgram(
                NAV_EXTRUCTION,
                PATIENT_POOL_ID,
                asset_,
                address(USDC),
                startBps,
                floorBps,
                startTime,
                duration,
                staleness,
                complianceGate,
                ++saltNonce
            );
        } else {
            (uint16 bandBps, uint32 staleness, uint256 usdcAmt, uint256 rwaAmt) =
                abi.decode(params, (uint16, uint32, uint256, uint256));
            (usdcAmount, rwaAmount) = (usdcAmt, rwaAmt);
            program = OutletPrograms.marketProgram(
                NAV_EXTRUCTION,
                MARKET_POOL_ID,
                asset_,
                address(USDC),
                bandBps,
                staleness,
                complianceGate,
                ++saltNonce
            );
        }

        uint256 free = USDC.balanceOf(address(this)) - reservedAssets;
        if (usdcAmount > free) revert InsufficientFreeCash(usdcAmount, free);
        uint256 shipped = shippedUsdcOf(asset_) + usdcAmount;
        if (shipped > perAssetCap[asset_]) {
            revert AssetCapExceeded(asset_, shipped, perAssetCap[asset_]);
        }

        ISwapVM.Order memory order = _buildOrder(program);

        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = asset_;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = usdcAmount;
        amounts[1] = rwaAmount;

        strategyHash = AQUA.ship(address(SWAP_VM), abi.encode(order), tokens, amounts);
        pools[strategyHash] = PoolInfo({asset: asset_, kind: kind, active: true});
        poolHashes.push(strategyHash);

        ROUTER.registerStrategy(asset_, order);

        emit PoolCreated(strategyHash, asset_, kind, usdcAmount, rwaAmount, params);
    }

    /// @notice Docks a strategy (zeroes its Aqua balances). Rebalance = dock + createPool.
    function dockPool(bytes32 strategyHash) external onlyCurator {
        PoolInfo storage info = pools[strategyHash];
        if (!info.active) revert PoolNotActive(strategyHash);
        info.active = false;

        address[] memory tokens = new address[](2);
        tokens[0] = address(USDC);
        tokens[1] = info.asset;
        AQUA.dock(address(SWAP_VM), strategyHash, tokens);
        ROUTER.delistStrategy(strategyHash);

        emit PoolDocked(strategyHash, info.asset);
    }

    /// @notice Live USDC currently shipped across this vault's active pools for `asset_`.
    function shippedUsdcOf(address asset_) public view returns (uint256 total) {
        for (uint256 i = 0; i < poolHashes.length; i++) {
            PoolInfo storage info = pools[poolHashes[i]];
            if (!info.active || info.asset != asset_) continue;
            (uint248 balance,) =
                AQUA.rawBalances(address(this), address(SWAP_VM), poolHashes[i], address(USDC));
            total += balance;
        }
    }

    // ------------------------------------------------------ curator: queue

    /// @notice Recycles accumulated RWA inventory into the asset's redemption queue — the
    ///         capital-reuse loop: buy at discount via pools, redeem at full NAV via the issuer.
    function recycle(address asset_, uint256 shares) external onlyCurator {
        if (!isMandateAsset[asset_]) revert AssetNotInMandate(asset_);
        RedemptionQueue queue = queueOf[asset_];
        uint256 epoch = queue.requestRedeem(shares, address(this), address(this));
        queuedShares[asset_] += shares;
        emit Recycled(asset_, shares, epoch);
    }

    /// @notice Claims settled queue epochs; curator ops fee is skimmed from proceeds.
    function claimQueue(address asset_, uint256 shares) external onlyCurator {
        RedemptionQueue queue = queueOf[asset_];
        uint256 proceeds = queue.redeem(shares, address(this), address(this));
        queuedShares[asset_] -= shares;

        uint256 fee = (proceeds * curatorFeeBps) / BPS;
        if (fee > 0 && curatorTreasury != address(0)) {
            USDC.safeTransfer(curatorTreasury, fee);
        }
        emit QueueClaimed(asset_, shares, proceeds, fee);
    }

    // ------------------------------------------------------------- internals

    function _buildOrder(bytes memory program) private view returns (ISwapVM.Order memory) {
        return MakerTraitsLib.build(
            MakerTraitsLib.Args({
                maker: address(this),
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

    function _requireFreshNavs() private view {
        for (uint256 i = 0; i < mandateAssets.length; i++) {
            address rwa = mandateAssets[i];
            if (IERC20(rwa).balanceOf(address(this)) + queuedShares[rwa] == 0) continue;
            (, uint40 updatedAt) = NAV_ORACLE.navOf(rwa);
            // stale NAV blocks valuation-sensitive flows (deposit, epoch fulfillment)
            if (block.timestamp - updatedAt > navMaxStaleness) revert StaleNav(rwa, updatedAt);
        }
    }

    /// @dev 10^(18 + rwaDecimals − usdcDecimals)
    function _rwaScale(address rwa) private view returns (uint256) {
        return 10
            ** (18 + IERC20Metadata(rwa).decimals() - IERC20Metadata(address(USDC)).decimals());
    }

    function mandateAssetsLength() external view returns (uint256) {
        return mandateAssets.length;
    }

    function poolCount() external view returns (uint256) {
        return poolHashes.length;
    }
}

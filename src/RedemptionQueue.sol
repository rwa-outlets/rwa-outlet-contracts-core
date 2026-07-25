// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title RedemptionQueue — ERC-7540 + ERC-7575 async redemption-only vault, one per RWA asset
/// @notice Ported from the validated `rwa-outlets-redemption_queue_simulation` prototype
///         (docs/03-contracts.md §2.5):
///  - ERC-7575 shape: `share()` is the RWA token itself (external share — this vault mints
///    nothing), `asset()` is USDC.
///  - Deposit side disabled (`maxDeposit == 0`, `deposit`/`mint` revert): ERC-7540 permits
///    single-sided async vaults.
///  - `requestId` = issuer batch epoch, so a whole window settles at one NAV.
///  - Lifecycle: Open (Pending) → submitToIssuer (still Pending) → settle (Claimable, pulls
///    settlement USDC in) → redeem (standard 4626 claim leg, FIFO epochs).
///  - Solvency is structural: claims pay only out of received settlement cash.
contract RedemptionQueue is Ownable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    enum EpochState {
        Open, // accepting requests (Pending)
        Submitted, // batched to the issuer (still Pending)
        Settled // settlement received (Claimable)
    }

    struct Epoch {
        EpochState state;
        uint256 totalShares; // RWA shares batched in this epoch
        uint256 navAtSettle; // 1e18, set at settlement
        uint256 submittedAt;
        uint256 settledAt;
    }

    // ---------------------------------------------------------------- state

    IERC20 public immutable rwa; // ERC-7575 share() — external share
    IERC20 public immutable usdc; // ERC-7575 asset()
    uint256 private immutable _shareScale; // 10 ** (shareDecimals + 18 - assetDecimals)

    address public curator; // batches epochs to the issuer (the AI agent)
    address public issuer; // delivers settlement cash
    address public feeRecipient; // queue-fee treasury
    uint16 public immutable queueFeeBps; // e.g. 5

    uint256 public currentEpoch = 1; // requests accumulate here
    uint256 public lastSettledEpoch; // epochs settle strictly in order
    uint256 public accruedFees; // USDC owed to feeRecipient

    mapping(uint256 epoch => Epoch) private _epochs;
    // shares requested per (epoch, controller); decremented on claim
    mapping(uint256 epoch => mapping(address controller => uint256)) public sharesAt;
    // FIFO bookkeeping per controller
    mapping(address controller => uint256[]) private _epochsOf;
    mapping(address controller => uint256) private _epochCursor;
    // ERC-7540 operator model
    mapping(address controller => mapping(address operator => bool)) public isOperator;

    // ---------------------------------------------------------------- events

    /// @dev ERC-7540 standard events
    event RedeemRequest(
        address indexed controller,
        address indexed owner,
        uint256 indexed requestId,
        address sender,
        uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    /// @dev ERC-4626 standard claim event
    event Withdraw(
        address indexed sender,
        address indexed receiver,
        address indexed controller,
        uint256 assets,
        uint256 shares
    );
    /// @dev ours
    event Submitted(uint256 indexed epoch, uint256 totalShares);
    event Settled(uint256 indexed epoch, uint256 navAtSettle, uint256 assetsIn);
    event FeesClaimed(address indexed recipient, uint256 amount);

    // ---------------------------------------------------------------- errors

    error NotAuthorized();
    error NotCurator();
    error NotIssuer();
    error ZeroShares();
    error EpochNotOpen(uint256 epoch);
    error EpochNotSubmitted(uint256 epoch);
    error EpochOutOfOrder(uint256 epoch, uint256 expected);
    error ExceedsClaimable(uint256 requested, uint256 claimable);
    error AsyncFlowOnly(); // previews / sync deposits are forbidden by ERC-7540

    // ---------------------------------------------------------------- setup

    constructor(
        IERC20 rwa_,
        IERC20 usdc_,
        address curator_,
        address issuer_,
        address feeRecipient_,
        uint16 queueFeeBps_
    ) Ownable(msg.sender) {
        rwa = rwa_;
        usdc = usdc_;
        curator = curator_;
        issuer = issuer_;
        feeRecipient = feeRecipient_;
        queueFeeBps = queueFeeBps_;
        // shares (shareDecimals) × nav (1e18) → assets (assetDecimals)
        _shareScale =
            10 ** (IERC20Metadata(address(rwa_)).decimals() + 18 - IERC20Metadata(address(usdc_)).decimals());
    }

    // ------------------------------------------------------- ERC-7575 views

    /// @notice ERC-7575: the share is the RWA token itself; this vault mints nothing.
    function share() external view returns (address) {
        return address(rwa);
    }

    /// @notice ERC-7575/4626: the settlement asset.
    function asset() external view returns (address) {
        return address(usdc);
    }

    /// @notice Settlement cash currently held (incl. accrued fees).
    function totalAssets() external view returns (uint256) {
        return usdc.balanceOf(address(this));
    }

    // ------------------------------------------------- ERC-7540 request leg

    /// @notice Escrows `shares` of the RWA and files them into the current issuer batch epoch.
    /// @dev `msg.sender` must be `owner` or an approved operator of `owner`.
    /// @return requestId The issuer batch epoch the request was filed into.
    function requestRedeem(uint256 shares, address controller, address owner_)
        external
        returns (uint256 requestId)
    {
        if (shares == 0) revert ZeroShares();
        if (msg.sender != owner_ && !isOperator[owner_][msg.sender]) revert NotAuthorized();

        requestId = currentEpoch;
        Epoch storage e = _epochs[requestId];
        // currentEpoch is always Open by construction

        rwa.safeTransferFrom(owner_, address(this), shares);

        if (sharesAt[requestId][controller] == 0) {
            _epochsOf[controller].push(requestId);
        }
        sharesAt[requestId][controller] += shares;
        e.totalShares += shares;

        emit RedeemRequest(controller, owner_, requestId, msg.sender, shares);
    }

    /// @notice ERC-7540: shares requested but not yet claimable for `controller` in `requestId`.
    function pendingRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares)
    {
        if (_epochs[requestId].state == EpochState.Settled) return 0;
        return sharesAt[requestId][controller];
    }

    /// @notice ERC-7540: shares claimable (settled, unclaimed) for `controller` in `requestId`.
    function claimableRedeemRequest(uint256 requestId, address controller)
        external
        view
        returns (uint256 shares)
    {
        if (_epochs[requestId].state != EpochState.Settled) return 0;
        return sharesAt[requestId][controller];
    }

    /// @notice ERC-7540 operator model: holders authorize the curator agent once, it auto-claims.
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // -------------------------------------------------------- issuer cycle

    /// @notice Curator batches the current epoch to the issuer window; a fresh epoch opens.
    function submitToIssuer(uint256 epoch) external {
        if (msg.sender != curator) revert NotCurator();
        if (epoch != currentEpoch) revert EpochNotOpen(epoch);
        Epoch storage e = _epochs[epoch];
        if (e.totalShares == 0) revert ZeroShares();

        e.state = EpochState.Submitted;
        e.submittedAt = block.timestamp;
        currentEpoch = epoch + 1;

        emit Submitted(epoch, e.totalShares);
    }

    /// @notice Issuer delivers settlement cash for `epoch` at `navAtSettle`; epoch → Claimable.
    /// @dev Pulls `totalShares × nav` (rounded up) from the issuer. Epochs settle in order so
    ///      the per-controller FIFO cursor is always sound. The escrowed RWA is released to the
    ///      issuer (redeemed against the fund).
    function settle(uint256 epoch, uint256 navAtSettle1e18) external {
        if (msg.sender != issuer) revert NotIssuer();
        Epoch storage e = _epochs[epoch];
        if (e.state != EpochState.Submitted) revert EpochNotSubmitted(epoch);
        if (epoch != lastSettledEpoch + 1) revert EpochOutOfOrder(epoch, lastSettledEpoch + 1);

        e.state = EpochState.Settled;
        e.navAtSettle = navAtSettle1e18;
        e.settledAt = block.timestamp;
        lastSettledEpoch = epoch;

        // gross settlement cash, rounded up — structural solvency
        uint256 assetsIn = (e.totalShares * navAtSettle1e18 + _shareScale - 1) / _shareScale;
        usdc.safeTransferFrom(issuer, address(this), assetsIn);
        // hand the escrowed RWA to the issuer for offchain redemption/burn
        rwa.safeTransfer(issuer, e.totalShares);

        emit Settled(epoch, navAtSettle1e18, assetsIn);
    }

    // ---------------------------------------------------------- claim leg

    /// @notice Standard 4626 claim leg: pays `shares × navAtSettle − queueFee`, FIFO epochs.
    /// @dev `msg.sender` must be `controller` or an approved operator of `controller`.
    function redeem(uint256 shares, address receiver, address controller)
        external
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        if (msg.sender != controller && !isOperator[controller][msg.sender]) {
            revert NotAuthorized();
        }

        uint256 remaining = shares;
        uint256[] storage epochs = _epochsOf[controller];
        uint256 cursor = _epochCursor[controller];

        while (remaining > 0 && cursor < epochs.length) {
            uint256 ep = epochs[cursor];
            Epoch storage e = _epochs[ep];
            if (e.state != EpochState.Settled) break; // FIFO stops at the first unsettled epoch

            uint256 avail = sharesAt[ep][controller];
            if (avail == 0) {
                cursor++;
                continue;
            }

            uint256 take = avail < remaining ? avail : remaining;
            sharesAt[ep][controller] = avail - take;
            remaining -= take;
            assets += (take * e.navAtSettle) / _shareScale; // gross, floor

            if (take == avail) cursor++;
        }
        _epochCursor[controller] = cursor;

        if (remaining > 0) revert ExceedsClaimable(shares, shares - remaining);

        uint256 fee = (assets * queueFeeBps) / 10_000;
        accruedFees += fee;
        assets -= fee;

        usdc.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, shares);
    }

    /// @notice ERC-7540: claimable shares for `controller` across settled epochs (FIFO-reachable).
    function maxRedeem(address controller) external view returns (uint256 shares) {
        uint256[] storage epochs = _epochsOf[controller];
        for (uint256 i = _epochCursor[controller]; i < epochs.length; i++) {
            if (_epochs[epochs[i]].state != EpochState.Settled) break;
            shares += sharesAt[epochs[i]][controller];
        }
    }

    /// @notice Fee treasury withdrawal.
    function claimFees() external {
        uint256 amount = accruedFees;
        accruedFees = 0;
        usdc.safeTransfer(feeRecipient, amount);
        emit FeesClaimed(feeRecipient, amount);
    }

    // --------------------------------- disabled 4626 legs (ERC-7540 rules)

    /// @notice Deposit side disabled — redemption-only vault.
    function maxDeposit(address) external pure returns (uint256) {
        return 0;
    }

    function maxMint(address) external pure returns (uint256) {
        return 0;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0; // claims go through redeem() only
    }

    function deposit(uint256, address) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    function mint(uint256, address) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    function withdraw(uint256, address, address) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    /// @dev ERC-7540: previews MUST revert for async flows.
    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    function previewWithdraw(uint256) external pure returns (uint256) {
        revert AsyncFlowOnly();
    }

    // ------------------------------------------------------------- getters

    function epochInfo(uint256 epoch) external view returns (Epoch memory) {
        return _epochs[epoch];
    }

    function epochsOf(address controller) external view returns (uint256[] memory) {
        return _epochsOf[controller];
    }

    function epochCursor(address controller) external view returns (uint256) {
        return _epochCursor[controller];
    }

    // -------------------------------------------------------------- admin

    function setRoles(address curator_, address issuer_, address feeRecipient_)
        external
        onlyOwner
    {
        curator = curator_;
        issuer = issuer_;
        feeRecipient = feeRecipient_;
    }
}

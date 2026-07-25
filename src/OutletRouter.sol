// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISwapVM} from "swap-vm/src/interfaces/ISwapVM.sol";
import {TakerTraitsLib} from "swap-vm/src/libs/TakerTraits.sol";

import {NavOracle} from "./NavOracle.sol";
import {RedemptionQueue} from "./RedemptionQueue.sol";
import {IRwaTwapSource} from "./interfaces/IRwaTwapSource.sol";

/// @title OutletRouter — best-of execution across outlet pools, resting bids, and the queue
/// @notice Single user entry point (docs/03-contracts.md §2.7). Holds no funds, only routes:
///         quotes every registered strategy for an asset through the official router's
///         `asView().quote(...)`, enforces the Uniswap v4 TWAP sanity band, executes the best
///         venue, and forwards patient exits to the asset's ERC-7540 RedemptionQueue.
contract OutletRouter is Ownable {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- types

    struct TwapGuard {
        IRwaTwapSource source; // RWAGateHook (zero = guard disabled)
        bytes32 poolId; // v4 PoolId of the RWA/USDC pool
        uint32 window; // TWAP window in seconds
        uint16 bandBps; // max deviation of program quotes from TWAP
    }

    // ---------------------------------------------------------------- state

    ISwapVM public immutable SWAP_VM; // official AquaSwapVMRouter
    IERC20 public immutable USDC;
    NavOracle public immutable NAV_ORACLE;

    uint256 public constant MAX_LISTINGS_PER_ASSET = 32;
    uint256 private constant BPS = 10_000;

    mapping(address asset => bytes32[]) private _listingsOf;
    mapping(bytes32 orderHash => bytes) public orderBlobOf; // abi.encode(ISwapVM.Order)
    mapping(bytes32 orderHash => address) public registrarOf;
    mapping(bytes32 orderHash => address) public assetOf;
    mapping(address asset => RedemptionQueue) public queueOf;
    mapping(address asset => TwapGuard) public guardOf;
    mapping(address token => bool) private _approved;

    // ---------------------------------------------------------------- events

    event StrategyRegistered(
        address indexed asset, bytes32 indexed orderHash, address indexed maker, address registrar
    );
    event StrategyDelisted(address indexed asset, bytes32 indexed orderHash);
    event QueueSet(address indexed asset, address queue);
    event GuardSet(address indexed asset, address source, bytes32 poolId, uint32 window, uint16 bandBps);
    event InstantExit(
        address indexed asset,
        address indexed user,
        bytes32 indexed orderHash,
        uint256 assetIn,
        uint256 usdcOut
    );
    event Purchase(
        address indexed asset,
        address indexed user,
        bytes32 indexed orderHash,
        uint256 usdcIn,
        uint256 assetOut
    );
    event PatientEnqueued(address indexed asset, address indexed user, uint256 indexed epoch, uint256 shares);

    // ---------------------------------------------------------------- errors

    error AlreadyListed(bytes32 orderHash);
    error NotListed(bytes32 orderHash);
    error NotRegistrar(bytes32 orderHash);
    error TooManyListings(address asset);
    error NoExecutableQuote(address asset, uint256 amount);
    error InsufficientOutput(uint256 out, uint256 minOut);
    error QuoteOutsideTwapBand(uint256 rate1e18, uint256 twap1e18, uint16 bandBps);
    error NoQueueForAsset(address asset);

    constructor(ISwapVM swapVM, IERC20 usdc, NavOracle navOracle) Ownable(msg.sender) {
        SWAP_VM = swapVM;
        USDC = usdc;
        NAV_ORACLE = navOracle;
    }

    // ---------------------------------------------------------- admin wiring

    function setQueue(address asset, RedemptionQueue queue) external onlyOwner {
        queueOf[asset] = queue;
        emit QueueSet(asset, address(queue));
    }

    function setGuard(
        address asset,
        IRwaTwapSource source,
        bytes32 poolId,
        uint32 window,
        uint16 bandBps
    ) external onlyOwner {
        guardOf[asset] = TwapGuard(source, poolId, window, bandBps);
        emit GuardSet(asset, address(source), poolId, window, bandBps);
    }

    // ------------------------------------------------------------- listings

    /// @notice Lists a pool strategy or resting bid so the router can quote it. Permissionless:
    ///         a listing is only ever *quoted* — execution safety comes from the official
    ///         router's settlement plus the taker threshold.
    function registerStrategy(address asset, ISwapVM.Order calldata order)
        external
        returns (bytes32 orderHash)
    {
        orderHash = SWAP_VM.hash(order);
        if (orderBlobOf[orderHash].length != 0) revert AlreadyListed(orderHash);
        if (_listingsOf[asset].length >= MAX_LISTINGS_PER_ASSET) revert TooManyListings(asset);

        _listingsOf[asset].push(orderHash);
        orderBlobOf[orderHash] = abi.encode(order);
        registrarOf[orderHash] = msg.sender;
        assetOf[orderHash] = asset;

        emit StrategyRegistered(asset, orderHash, order.maker, msg.sender);
    }

    function delistStrategy(bytes32 orderHash) external {
        if (orderBlobOf[orderHash].length == 0) revert NotListed(orderHash);
        if (msg.sender != registrarOf[orderHash] && msg.sender != owner()) {
            revert NotRegistrar(orderHash);
        }
        address asset = assetOf[orderHash];

        bytes32[] storage list = _listingsOf[asset];
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == orderHash) {
                list[i] = list[list.length - 1];
                list.pop();
                break;
            }
        }
        delete orderBlobOf[orderHash];
        delete registrarOf[orderHash];
        delete assetOf[orderHash];

        emit StrategyDelisted(asset, orderHash);
    }

    function listingsOf(address asset) external view returns (bytes32[] memory) {
        return _listingsOf[asset];
    }

    // ------------------------------------------------------------- quoting

    /// @notice Best instant-exit quote (asset → USDC) across all listings.
    function quoteInstant(address asset, uint256 amount)
        public
        view
        returns (bytes32 bestHash, uint256 bestOut)
    {
        return _bestQuote(asset, address(USDC), asset, amount);
    }

    /// @notice Best entry quote (USDC → asset) across all listings (two-sided Market pools).
    function quoteBuy(address asset, uint256 usdcIn)
        public
        view
        returns (bytes32 bestHash, uint256 bestOut)
    {
        return _bestQuote(asset, asset, address(USDC), usdcIn);
    }

    function _bestQuote(address asset, address tokenOut, address tokenIn, uint256 amount)
        private
        view
        returns (bytes32 bestHash, uint256 bestOut)
    {
        bytes32[] storage list = _listingsOf[asset];
        bytes memory takerBytes = _takerData(0, address(0));

        for (uint256 i = 0; i < list.length; i++) {
            ISwapVM.Order memory order = abi.decode(orderBlobOf[list[i]], (ISwapVM.Order));
            try SWAP_VM.quote(order, tokenIn, tokenOut, amount, takerBytes) returns (
                uint256, uint256 amountOut, bytes32
            ) {
                if (amountOut > bestOut) {
                    bestOut = amountOut;
                    bestHash = list[i];
                }
            } catch {
                // stale NAV, expired auction, drained inventory, … — listing simply not executable
            }
        }
    }

    // ------------------------------------------------------------ execution

    /// @notice Instant exit: sells `amount` of `asset` for USDC at the best available quote.
    function redeemInstant(address asset, uint256 amount, uint256 minOut)
        external
        returns (uint256 usdcOut)
    {
        (bytes32 bestHash, uint256 bestOut) = quoteInstant(asset, amount);
        if (bestHash == bytes32(0)) revert NoExecutableQuote(asset, amount);
        if (bestOut < minOut) revert InsufficientOutput(bestOut, minOut);
        _checkTwapBand(asset, Math.mulDiv(bestOut, _scale(asset), amount));

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _ensureApproved(asset);

        ISwapVM.Order memory order = abi.decode(orderBlobOf[bestHash], (ISwapVM.Order));
        (, usdcOut,) = SWAP_VM.swap(
            order, asset, address(USDC), amount, _takerData(minOut, msg.sender)
        );

        emit InstantExit(asset, msg.sender, bestHash, amount, usdcOut);
    }

    /// @notice Entry: buys `asset` with `usdcIn` at the best available quote.
    function buy(address asset, uint256 usdcIn, uint256 minOut)
        external
        returns (uint256 assetOut)
    {
        (bytes32 bestHash, uint256 bestOut) = quoteBuy(asset, usdcIn);
        if (bestHash == bytes32(0)) revert NoExecutableQuote(asset, usdcIn);
        if (bestOut < minOut) revert InsufficientOutput(bestOut, minOut);
        _checkTwapBand(asset, Math.mulDiv(usdcIn, _scale(asset), bestOut));

        USDC.safeTransferFrom(msg.sender, address(this), usdcIn);
        _ensureApproved(address(USDC));

        ISwapVM.Order memory order = abi.decode(orderBlobOf[bestHash], (ISwapVM.Order));
        (, assetOut,) = SWAP_VM.swap(
            order, address(USDC), asset, usdcIn, _takerData(minOut, msg.sender)
        );

        emit Purchase(asset, msg.sender, bestHash, usdcIn, assetOut);
    }

    /// @notice Patient exit: forwards to the asset's ERC-7540 queue. UX sugar — requires the
    ///         user to have approved the RWA to the queue and set this router as ERC-7540
    ///         operator (or call the queue directly).
    function enqueue(address asset, uint256 amount) external returns (uint256 epoch) {
        RedemptionQueue queue = queueOf[asset];
        if (address(queue) == address(0)) revert NoQueueForAsset(asset);
        epoch = queue.requestRedeem(amount, msg.sender, msg.sender);
        emit PatientEnqueued(asset, msg.sender, epoch, amount);
    }

    // ------------------------------------------------------------- internals

    /// @dev Program quotes deviating more than `bandBps` from the v4 TWAP revert unless the
    ///      NavOracle is fresher than the TWAP window (docs/03-contracts.md §2.7). Guard is
    ///      inactive until configured or while the hook lacks history.
    function _checkTwapBand(address asset, uint256 rate1e18) private view {
        TwapGuard memory g = guardOf[asset];
        if (address(g.source) == address(0)) return;

        try g.source.twapRate(g.poolId, g.window) returns (uint256 twap1e18) {
            if (twap1e18 == 0) return;
            uint256 deviationBps = rate1e18 > twap1e18
                ? ((rate1e18 - twap1e18) * BPS) / twap1e18
                : ((twap1e18 - rate1e18) * BPS) / twap1e18;
            if (deviationBps > g.bandBps) {
                (, uint40 navUpdatedAt) = NAV_ORACLE.navOf(asset);
                if (block.timestamp - navUpdatedAt > g.window) {
                    revert QuoteOutsideTwapBand(rate1e18, twap1e18, g.bandBps);
                }
            }
        } catch {
            // no TWAP history yet — guard not enforceable
        }
    }

    function _takerData(uint256 minOut, address to) private view returns (bytes memory) {
        return TakerTraitsLib.build(
            TakerTraitsLib.Args({
                taker: address(this),
                isExactIn: true,
                shouldUnwrapWeth: false,
                isStrictThresholdAmount: false,
                isFirstTransferFromTaker: true,
                useTransferFromAndAquaPush: true,
                threshold: minOut == 0 ? bytes("") : abi.encodePacked(minOut),
                to: to,
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

    function _ensureApproved(address token) private {
        if (!_approved[token]) {
            IERC20(token).forceApprove(address(SWAP_VM), type(uint256).max);
            _approved[token] = true;
        }
    }

    /// @dev 10^(18 + assetDecimals − usdcDecimals): converts asset amounts × rate → USDC amounts.
    function _scale(address asset) private view returns (uint256) {
        return 10
            ** (18 + IERC20Metadata(asset).decimals() - IERC20Metadata(address(USDC)).decimals());
    }
}

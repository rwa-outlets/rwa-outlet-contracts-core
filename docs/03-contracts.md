# RWA Outlets — Contracts to build (page 3)

Build list for the hackathon, derived from `02-engine-spec.md`. Guiding rule: **the swap engine is
the official deployed 1inch stack — we only build what plugs into it.**

## 0. What we do NOT build

| Contract | Why not |
|---|---|
| `Aqua` | Official, deployed (`0x4999…6d31`). Mainnet-fork demo uses it as-is; Base Sepolia gets a redeploy of the official bytecode (allowed; never reimplemented) |
| `AquaSwapVMRouter` | Official, deployed (`0x8fdd…958f`) — the VM and the Aqua app. Same fork/redeploy policy |
| Uniswap v4 `PoolManager` | Canonical deployments on target chains |
| `OutletApp`, `OutletVM`, `OutletOpcodes`, `ComplianceRegistry` | Cut from the design — replaced by the official router, `NavExtruction`, and `ComplianceNFT` |

## 1. Build list (8 contracts)

| # | Contract | One-liner | Milestone | Est. LOC | Depends on |
|---|---|---|---|---|---|
| 1 | `NavOracle` | Per-asset NAV + staleness | M1 | ~80 | — |
| 2 | `ComplianceNFT` | Soulbound ERC-721 KYC pass | M1 | ~60 | OZ ERC-721 |
| 3 | `NavExtruction` | Custom pricing instruction (all 3 pool modes) | M1 (fixed) / M2 (decay, band) | ~250 | swap-vm interfaces, `NavOracle` |
| 4 | `RWAToken` + `TestUSDC` | Demo assets (18d RWA, 6d USDC) | M1 | ~110 | OZ ERC-20 |
| 5 | `RedemptionQueue` | ERC-7540/7575 async redemption vault (per asset) | M2 | ~280 | OZ ERC-4626 + 7540/7575 interfaces |
| 6 | `RWAGateHook` | v4 hook: compliance gate + TWAP | M3 | ~200 | v4-periphery `BaseHook`, `ComplianceNFT` |
| 7 | `OutletRouter` | Best-of execution across pools / bids / v4 | M3 | ~300 | swap-vm `ISwapVM`, `RWAGateHook`, `RedemptionQueue` |
| 8 | `CuratorVault` | USDC-only tier vault; curator runs pools across the tier's RWAs | M3 | ~350 | OZ ERC-4626, 7540 interfaces, `IAqua`, `NavOracle`, `RedemptionQueue` |
| 9 | `V4Venue` | v4 execution leg: pool registry + quoter + unlock-callback swaps (router fallback venue) | M3 | ~200 | v4-core, v4-periphery `V4Quoter`, `RWAGateHook` |

Everything else in the repo is scripts (`Deploy.s.sol`, `Demo.s.sol`, NAV keeper) and the test
harness (fork tests against mainnet Aqua/router, quote==swap invariant suite reusing swap-vm's
`AquaOpcodesDebug` + `ProgramBuilder` test utils).

## 2. Contract specs

### 2.1 `NavOracle` (M1)

Per-asset NAV pushed by a keeper (demo: the curator agent). Consumers read raw values and decide
staleness themselves — `NavExtruction` reverts on its own `maxStaleness` arg.

```solidity
function setNav(address asset, uint256 nav1e18) external onlyKeeper;
function navOf(address asset) external view returns (uint256 nav1e18, uint40 updatedAt);
event NavUpdated(address indexed asset, uint256 nav, uint256 timestamp);
```

### 2.2 `ComplianceNFT` (M1)

Non-transferable ERC-721: mint/revoke by operator, transfers revert (`_update` override). Exists to
be read by `balanceOf`-based gates: the stock SwapVM opcodes (`_onlyTakerTokenBalanceNonZero`,
`_onlyTxOriginTokenBalanceNonZero`) and `RWAGateHook`. Standard Transfer events give the subgraph
the KYC set for free.

```solidity
function mint(address to) external onlyOperator returns (uint256 id);
function revoke(address holder) external onlyOperator;
```

### 2.3 `NavExtruction` (M1 fixed-spread; M2 decay + band) — the core custom contract

Implements the official `IExtruction`/`IStaticExtruction` duals as **one** function (identical
selector): branch on `isStaticContext`, no state writes and no events in static mode so `quote()`
works under staticcall. Immutable, references `NavOracle`, deterministic per block — the official
Extruction contract requires quote/swap consistency and forbids backward jumps to it.

```solidity
enum Mode { FixedSpread, DutchDecay, NavBand }
// program args: abi.encodePacked(mode, poolId, asset, <mode params>)
//   FixedSpread: (spreadBps, maxStaleness)               → amounts at NAV × (1 − spread)
//   DutchDecay:  (startBps, floorBps, startTime, duration) → discount decays to floor; expiry reverts
//   NavBand:     (bandBps, maxStaleness)                 → post-check on amounts set by _xycSwapXD

function extruction(
    bool isStaticContext, uint256 nextPC,
    SwapQuery calldata query, SwapRegisters calldata swap,
    bytes calldata args, bytes calldata takerData
) external returns (uint256 updatedNextPC, uint256 choppedLength, SwapRegisters memory updatedSwap);

event Trade(bytes32 indexed pool, address indexed asset, bool isExit, address maker, address taker,
            uint256 amountIn, uint256 amountOut, int256 rateVsNavBps); // swap mode only
```

Must handle: exactIn and exactOut, both trade directions, decimal scaling (RWA 18 / USDC 6, NAV
1e18), rounding in the maker's favor. Returns `nextPC` unchanged, `choppedLength = 0`. This is the
1inch "custom instructions" deliverable — spend the audit attention here.

### 2.4 `RWAToken` / `TestUSDC` (M1)

`RWAToken`: 18-decimals ERC-20, issuer-mintable, optional compliance-gated transfers (checks
`ComplianceNFT` when the gated flag is set) — the "hard" KYC line. Demo instances: `rwaTBILL`
(T+7), `rwaCREDIT` (T+90). `TestUSDC`: 6-decimals mintable ERC-20 for Base Sepolia only (fork demo
uses real USDC).

### 2.5 `RedemptionQueue` (M2) — ERC-7540 + ERC-7575

An **asynchronous redemption-only vault, one instance per RWA asset** — ERC-7540 is the standard
built for exactly this (issuer-delayed RWA redemptions; Centrifuge lineage). ERC-7575 shape: the
vault mints nothing — `share()` returns the RWA token itself (external share), `asset()` is USDC.
Deposit side disabled (`maxDeposit == 0`, `deposit`/`mint` revert); 7540 permits single-sided async
vaults. `requestId` = **issuer batch epoch**, so a whole window settles at one NAV.

```solidity
// standard ERC-7540 surface
function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 epoch);
function pendingRedeemRequest(uint256 epoch, address controller) external view returns (uint256 shares);
function claimableRedeemRequest(uint256 epoch, address controller) external view returns (uint256 shares);
function setOperator(address operator, bool approved) external;   // holders authorize the curator agent once
function share() external view returns (address);                 // ERC-7575: the RWA token
function redeem(uint256 shares, address receiver, address controller) external returns (uint256 assets);
                                                                   // 4626 claim leg: shares × navAtSettle − queueFee, FIFO epochs
// ours
function submitToIssuer(uint256 epoch) external onlyCurator;               // batch → issuer window (stays Pending)
function settle(uint256 epoch, uint256 navAtSettle1e18) external onlyIssuer; // pulls USDC in, epoch → Claimable
```

Conformance notes: `previewRedeem`/`previewWithdraw` MUST revert (async flows), the Claimable
state must be observable (never skipped), `maxRedeem(controller)` = claimable shares, standard
`RedeemRequest`/`OperatorSet`/`Withdraw` events. Solvency is structural: claims pay only out of
settlement cash received. The operator model doubles as the agent story — the curator auto-claims
for users when epochs settle. (OZ community-contracts has an `ERC7540` base, but it assumes
vault-minted shares; our external-share shape means we write the request book ourselves.)

### 2.6 `RWAGateHook` (M3)

Uniswap v4 hook on the RWA/USDC pool. `beforeSwap` / `beforeAddLiquidity`: require the initiating
user (from hookData) holds `ComplianceNFT`. `afterSwap`: maintain a minimal price accumulator (ring
buffer or EMA) exposing `twap(window)` — the router's sanity bound. This is the Uniswap-track
deliverable; keep the oracle minimal but real.

### 2.7 `OutletRouter` (M3)

Single user entry point; holds no funds, only routes.

```solidity
function registerStrategy(ISwapVM.Order calldata order) external;   // curator/maker lists a pool or resting bid
function redeemInstant(address asset, uint256 amount, uint256 minOut) external returns (uint256 usdcOut);
function buy(address asset, uint256 usdcIn, uint256 minOut) external returns (uint256 rwaOut);
function enqueue(address asset, uint256 amount) external returns (uint256 epoch);
// patient mode: forwards to the asset's queue requestRedeem(amount, user, user) —
// requires the user to have approved the RWA to the queue and set the router as ERC-7540 operator
// (or the user calls the queue directly; the router call is just UX sugar)
```

Quoting: `swapVM.asView().quote(...)` over registered strategies (same takerData reused for
`swap()`), plus the v4 pool through `V4Venue` (`quoteInstantAll`/`quoteBuyAll` — non-view since
the official `V4Quoter` simulates via revert; call via `eth_call`); executes the best venue.
Enforces the TWAP band: program quotes deviating > `twapBandBps` from `RWAGateHook.twap()` revert
unless `NavOracle` is fresher than the TWAP window. Gated assets rely on the program-level
tx.origin NFT gate (§3 of the engine spec) plus token-level restrictions. `V4Venue` (solc 0.8.26
unit, reached through the pragma-neutral `IV4Venue`) registers one asset/USDC pool per RWA,
forwards the real user as hookData for the compliance gate, and settles swaps in its own
`unlockCallback` (swap → settle input → take output to the user); `script/SetupV4Pool.s.sol`
initializes the pools at NAV, seeds demo liquidity, and wires the router.

### 2.8 `CuratorVault` (M3) — the B2C capital vault

One vault per **risk tier**: LPs deposit **USDC only**; the vault operates every mandate RWA of
its tier through the pool strategies it creates — it is the strategy creator on Aqua/SwapVM, a
**contract maker** (`useAquaInsteadOfSignature` needs no EOA signature). ERC-4626 with an
ERC-7540 async redeem side; the vault is its own ERC-20 share and `share() == address(this)`
covers the ERC-7575 conformance 7540 requires. This is Liquid Lane's curated-vault leg rebuilt on
Aqua.

```solidity
// LP side (USDC only)
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
                        // sync 4626 mint at NAV-based share price; reverts on stale NAV; optional ComplianceNFT gate
function requestRedeem(uint256 shares, address controller, address owner) external returns (uint256 epoch);
                        // async 7540 exit; curator frees capital, then epoch → Claimable → redeem()

// curator side (the agent) — one treasury, many per-asset pools
struct Mandate { address[] allowedAssets; uint256 perAssetCap; uint16 maxDiscountFloorBps; uint16 curatorFeeBps; }
function createPool(address asset, PoolType kind, bytes calldata params) external onlyCurator returns (bytes32 strategyHash);
                        // reverts if asset ∉ mandate; builds order (maker = vault), approves Aqua, ship()s
function dockPool(bytes32 strategyHash) external onlyCurator;         // rebalance = dock + createPool
function recycle(address asset, uint256 amount) external onlyCurator; // RWA inventory → RedemptionQueue.requestRedeem
function fulfillRedeemEpoch(uint256 epoch) external onlyCurator;      // moves freed USDC to Claimable for LP exits
```

`totalAssets()` = idle USDC + shipped Aqua balances (`rawBalances`) + the multi-RWA inventory and
queue positions at `NavOracle` value. LP exits settle at realized values through epochs (no
oracle-priced instant exit), which closes the classic 4626 stale-price arbitrage. Pro makers are
unaffected — both maker classes ship the same order templates to the same official router.

## 3. Build order

1. **M1 (1inch qualification):** `NavOracle` → `ComplianceNFT` → `NavExtruction` (FixedSpread) →
   demo tokens → `script/Demo.s.sol` fork test: ship USDC to the official mainnet router, swap a
   real RWA through Pool 1.
2. **M2:** `NavExtruction` DutchDecay + NavBand modes → `RedemptionQueue` → resting-bid flow
   (script only — a bid is just a small shipped strategy).
3. **M3:** `CuratorVault` (mandate + agent-as-curator wiring) → `RWAGateHook` → `OutletRouter` →
   Base Sepolia deploy (incl. official Aqua + router redeploys) → `deployments/<chain>.json`.

Offchain (separate repos/packages, not contracts): subgraph, curator agent, NAV keeper.

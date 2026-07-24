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

## 1. Build list (7 contracts)

| # | Contract | One-liner | Milestone | Est. LOC | Depends on |
|---|---|---|---|---|---|
| 1 | `NavOracle` | Per-asset NAV + staleness | M1 | ~80 | — |
| 2 | `ComplianceNFT` | Soulbound ERC-721 KYC pass | M1 | ~60 | OZ ERC-721 |
| 3 | `NavExtruction` | Custom pricing instruction (all 3 pool modes) | M1 (fixed) / M2 (decay, band) | ~250 | swap-vm interfaces, `NavOracle` |
| 4 | `RWAToken` + `TestUSDC` | Demo assets (18d RWA, 6d USDC) | M1 | ~110 | OZ ERC-20 |
| 5 | `RedemptionQueue` | Claim-NFT escrow, NAV settlement | M2 | ~200 | OZ ERC-721, `NavOracle` |
| 6 | `RWAGateHook` | v4 hook: compliance gate + TWAP | M3 | ~200 | v4-periphery `BaseHook`, `ComplianceNFT` |
| 7 | `OutletRouter` | Best-of execution across pools / bids / v4 | M3 | ~300 | swap-vm `ISwapVM`, `RWAGateHook`, `RedemptionQueue` |

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

### 2.5 `RedemptionQueue` (M2)

ERC-721 claim tickets over escrowed RWA. States `Pending → SubmittedToIssuer → Settled → Claimed`.
Solvency is structural: `claim` pays only out of settlement cash received.

```solidity
function enqueue(address asset, uint256 amount) external returns (uint256 id); // mints ticket (asset, amount, navAtEnqueue)
function submitToIssuer(address asset, uint256[] calldata ids) external onlyCurator;
function settle(address asset, uint256 navAtSettle1e18) external onlyIssuer;   // pulls USDC in
function claim(uint256 id) external;                                           // amount × navAtSettle − queueFee
event Enqueued(uint256 id, address asset, uint256 amount, uint256 nav);
event Submitted(uint256 id); event Settled(address asset, uint256 nav); event Claimed(uint256 id, uint256 payout);
```

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
function enqueue(address asset, uint256 amount) external returns (uint256 ticketId); // passthrough
```

Quoting: `swapVM.asView().quote(...)` over registered strategies (same takerData reused for
`swap()`), plus the v4 pool; executes the best venue. Enforces the TWAP band: program quotes
deviating > `twapBandBps` from `RWAGateHook.twap()` revert unless `NavOracle` is fresher than the
TWAP window. Gated assets rely on the program-level tx.origin NFT gate (§3 of the engine spec) plus
token-level restrictions.

## 3. Build order

1. **M1 (1inch qualification):** `NavOracle` → `ComplianceNFT` → `NavExtruction` (FixedSpread) →
   demo tokens → `script/Demo.s.sol` fork test: ship USDC to the official mainnet router, swap a
   real RWA through Pool 1.
2. **M2:** `NavExtruction` DutchDecay + NavBand modes → `RedemptionQueue` → resting-bid flow
   (script only — a bid is just a small shipped strategy).
3. **M3:** `RWAGateHook` → `OutletRouter` → Base Sepolia deploy (incl. official Aqua + router
   redeploys) → `deployments/<chain>.json`.

Offchain (separate repos/packages, not contracts): subgraph, curator agent, NAV keeper.

# RWA Outlets — Engine spec (page 2 of 3)

Contract-level spec for the engine described in `01-architecture.md`. Stack: Foundry, Solidity
^0.8.24, official 1inch contracts via `forge install 1inch/aqua 1inch/swap-vm`, **used as deployed,
no VM fork**: Aqua `0x499943e74fb0ce105688beee8ef2abec5d936d31` and SwapVM
`0x8fdd04dbf6111437b44bbca99c28882434e0958f` (unified address on 12 chains incl. Base; verified
onchain as `AquaSwapVMRouter` = SwapVM core + `AquaOpcodes` instruction set). Custom logic enters
only through the official `_extruction` opcode. Redeploying official code to Base Sepolia is
allowed, never reimplementing it.

## 1. Contract map

| Contract | Inherits | Role |
|---|---|---|
| `AquaSwapVMRouter` | — (official, deployed) | The VM **and** the Aqua app: runs pool programs, seeds registers from shipped balances, settles `pull()`/`push()` and verifies taker payment behind a per-order reentrancy lock. Used as-is at `0x8fdd…958f` |
| `Aqua` | — (official, deployed) | Shared virtual balances: `ship`/`dock` (liquidity), `pull`/`push` (swap-time settlement) |
| `NavExtruction` | `IExtruction`, `IStaticExtruction` | Our custom instruction, plugged in via the stock `_extruction` opcode: NAV-anchored spread (Pool 1), Dutch decay (Pool 2), NAV band check (Pool 3); stale-NAV revert; emits `Trade` during swaps |
| `ComplianceNFT` | ERC-721 (soulbound) | KYC pass: mint/revoke by operator; checked onchain by stock balance-gate opcodes and by `RWAGateHook` |
| `RedemptionQueue` | ERC-7540 + ERC-7575 (redemption-only vault per asset) | Escrows redemption requests by issuer epoch (`share()` = the RWA token, `asset()` = USDC); settlement flips epochs Claimable; standard `redeem()` pays NAV |
| `CuratorVault` | ERC-4626 + ERC-7540 (async redeem; `share()` per 7575) | One vault per **risk tier**: USDC-only deposits, epoch-fulfilled LP exits; operates every mandate RWA of its tier — the curator (AI agent) creates/docks pools per asset and recycles inventory through the queue |
| `OutletRouter` | — | Single user entry point: best-of quoting across Pools 1–3 / resting bids / Uniswap, and queue deposits |
| `NavOracle` | — | Per-asset NAV pushed by issuer keeper (demo: agent-updated), with staleness bounds |
| `RWAGateHook` | v4 `BaseHook` | Uniswap v4 hook: transfer compliance + TWAP exposure for the secondary lane |
| `V4Venue` | `IUnlockCallback` | Uniswap v4 execution leg: per-asset RWA/USDC pool registry, exact-in quotes via the official `V4Quoter`, swaps settled through its own unlock callback; the router routes here when v4 beats every Aqua quote |

## 2. Aqua integration (shared capital base)

The official router is itself the Aqua app — no app contract of ours sits in the swap path.

- A **pool** is an order template: `MakerTraitsLib.build(...)` carries the pool's program bytes and
  `useAquaInsteadOfSignature: true` (shipped liquidity replaces EIP-712 signatures). Per maker ×
  asset, `strategy = abi.encode(order)` and `aqua.ship(swapVM, strategy, [rwa, usdc], amounts)`;
  `strategyHash == orderHash == keccak256(strategy)`, balances live at
  `balances[maker][swapVM][orderHash][token]`.
- At swap time the router seeds the VM registers from `AQUA.safeBalances(...)`, settles maker→taker
  via `pull()`, and verifies the taker's payment (direct `push()` or transferFrom-then-push) behind
  a per-order reentrancy lock — all inside the official contract.
- Shared capital: the same wallet USDC backs every pool strategy a maker ships (and any other Aqua
  app). Fills are hard-capped by shipped balances, so **no invalidators are needed**; cancel =
  `dock()`.
- Strategies are immutable (`StrategiesMustBeImmutable`): changing pool params = dock + ship a new
  order. NAV movement does *not* require re-shipping — programs read NAV live via `NavExtruction`.
- Taker side always calls `quote()` via `asView()` with the *same* takerData later passed to
  `swap()`, plus threshold and deadline.
- A maker is either a **pro wallet** (B2B) or a **`CuratorVault`** pooling retail deposits (B2C,
  §5) — identical from Aqua's perspective: `useAquaInsteadOfSignature` means no EOA signature, so a
  contract maker works out of the box.

## 3. SwapVM programs (instruction order is security-critical)

Everything runs on the deployed `AquaSwapVMRouter`. Its `AquaOpcodes` set (verified against
`main`): control flow (`_jump`, `_jumpIfTokenIn/Out`, `_deadline`, `_salt`), taker gates
(`_onlyTakerTokenBalanceNonZero`/`Gte`, `_onlyTakerTokenSupplyShareGte`,
`_onlyTxOriginTokenBalanceNonZero`), pricing (`_xycSwapXD`, `_xycConcentrateGrowLiquidity2D`,
`_peggedSwapGrowPriceRange2D`), MEV protection (`_decayXD` — Mooniswap-style virtual-balance decay,
**not** a Dutch auction), fees (`_flatFeeAmountInXD`, `_protocolFeeAmountInXD` + Aqua/dynamic
variants), and the extension hook `_extruction`.

*Not* in the deployed set: `_limitSwap1D`, `_requireMinRate1D`, `_dutchAuctionBalanceIn/Out1D`,
`_staticBalancesXD`/`_dynamicBalancesXD`, invalidators, whitelists, TWAP — those live in the
`Opcodes`/`LimitOpcodes` router flavors, which 1inch has not deployed. We don't need them; if that
changes, deploying the official `LimitSwapVMRouter` bytecode is permitted.

Aqua strategies need no balance instruction (registers come from shipped balances). Order within a
program: gates → fees → pricing.

**Pool 1 — Express** (fixed NAV-anchored spread):

```text
_onlyTakerTokenBalanceNonZero(complianceNFT)   // stock KYC gate — "NFTs are natively supported"
_flatFeeAmountInXD(protocolFeeBps)             // fee taken before pricing
_extruction(navExtruction, (asset, spreadBps, maxStaleness))
                                               // amounts at NAV × (1 − spread); stale NAV reverts
```

**Pool 2 — Patient** (Dutch decay replaces RFQ bidding):

```text
_onlyTakerTokenBalanceNonZero(complianceNFT)
_flatFeeAmountInXD(protocolFeeBps)
_extruction(navExtruction, (asset, startBps, floorBps, startTime, duration))
                                               // discount decays to the floor; expiry reverts
```

**Pool 3 — Market** (two-sided xyc AMM):

```text
_flatFeeAmountInXD(ammFeeBps)                  // swap fee, accrues to the maker's reserves
_decayXD(decayPeriod)                          // optional stock MEV shield (virtual-reserve restoration)
_xycSwapXD()                                   // constant product over shipped balances
_extruction(navExtruction, (asset, bandBps))   // optional post-check: fill must sit inside NAV band
```

The Pool 3 order is a standing curve: each fill moves the maker's shipped reserves and therefore
the next price, exactly like an AMM pool, except the "pool" is the maker's wallet.

### NavExtruction — custom instruction without a VM fork

`NavExtruction` implements the official `IExtruction` (swap) and `IStaticExtruction` (quote)
interfaces and is invoked by the stock `_extruction` opcode, so custom pricing runs on the
untouched official router. Constraints inherited from the official spec: deterministic, the
quote/swap duals must return identical amounts, no backward jumps to it, contract immutable. Modes
selected by args: fixed NAV spread, Dutch decay (exponential per-second factor, mirroring the
official `DutchAuction` math, with hard floor and expiry), NAV band post-check. Reads `NavOracle`
and reverts on staleness; in swap mode it also emits the `Trade` event with full pricing context
(§7).

### KYC — a soulbound NFT, not a registry

`ComplianceNFT` is a non-transferable ERC-721 minted/revoked per KYC'd address. Programs gate on it
with stock opcodes: `_onlyTakerTokenBalanceNonZero` when the user fills directly,
`_onlyTxOriginTokenBalanceNonZero` when the fill routes through `OutletRouter` (taker = router).
The tx.origin variant is documented as weak (interceptable flows, breaks smart-wallet users) — an
acceptable gate for a discount venue, since the hard compliance line stays at the RWA token itself
and at `RWAGateHook` on v4. Maker-side verification mirrors Liquid Lane: shipping makers hold the
same NFT, checked by the curator agent.

### Isolated resting bids (optional maker mode)

Because `strategyHash == orderHash`, every shipped order is already **order-scoped**: shipping a
small dedicated strategy — fixed-rate `NavExtruction` program + `_deadline`, funded with exactly
the bid size — is a ring-fenced resting bid at a hand-picked discount, the closest analog to
Liquid Lane's RFQ bids. No signatures, no extra router; `OutletRouter` treats these as additional
quote sources.

## 4. RedemptionQueue (delayed lane) — ERC-7540 + ERC-7575

One **redemption-only async vault per RWA asset**, modeling the issuer delay with the standard
lifecycle `Pending → Claimable → Claimed`. ERC-7575 shape: `share()` is the RWA token itself (an
external share — the vault mints nothing), `asset()` is USDC. Deposit side disabled
(`maxDeposit == 0`); ERC-7540 allows single-sided async vaults.

- `requestRedeem(shares, controller, owner)` escrows the RWA and emits the standard
  `RedeemRequest`; `requestId` = the current **issuer batch epoch**, so all requests in a window
  settle at the same NAV. Tracked by `pendingRedeemRequest(epoch, controller)`.
- Curator agent calls `submitToIssuer(epoch)` per issuer window (still Pending).
- `settle(epoch, navAtSettle)` (issuer keeper) pulls settlement USDC in and flips the epoch to
  Claimable — the Claimable state is observable and never skipped, as the spec requires.
- Claim is the standard 4626 leg: `redeem(shares, receiver, controller)` pays
  `shares × navAtSettle − queueFee`, consuming claimable epochs FIFO.
  `previewRedeem`/`previewWithdraw` revert (mandatory for async flows);
  `maxRedeem(controller)` = claimable shares.
- **Operator model = agent hook**: holders `setOperator(curatorAgent, true)` once and the agent
  auto-claims when settlement lands — standard-conformant automation, logged for the Graph track.
- Payouts come only from received settlement cash, so the queue cannot be insolvent by construction.
- Spread waterfall on maker-recycled inventory: maker keeps the NAV−discount capture minus
  `curatorFeeBps` (agent treasury) and `protocolFeeBps`.

## 5. CuratorVault (B2C capital) — ERC-4626 + ERC-7540, USDC-only deposits

Where retail capital enters: one vault **per risk tier**. LPs deposit **only USDC** (the
stablecoin side is the sole entry point); the multi-asset dimension is operational — the vault
trades and holds **all mandate RWA tokens of its tier** through the pool strategies it creates
(Express tier = T-bill-class assets; Patient tier = private-credit assets).

- Deposits are synchronous 4626 (`deposit()` mints vault shares at the NAV-based share price); LP
  exits are asynchronous ERC-7540 (`requestRedeem` → curator frees capital → epoch turns
  Claimable) — the same single-sided async pattern as the `RedemptionQueue`. The vault is its own
  ERC-20 share; `share() == address(this)` satisfies the ERC-7575 conformance that 7540 mandates
  (the multi-entry-point 7575 shape is unnecessary with a single USDC entry).
- **Mandate** (immutable per vault): the tier's asset set, per-asset caps, maximum discount floor,
  fee split. `createPool(asset, poolType, params)` is curator-only and reverts for out-of-mandate
  assets; it builds the pool order with `maker = vault` (`NavExtruction` program per §3), approves
  Aqua, and `ship()`s — the vault, not an EOA, is the strategy creator on Aqua/SwapVM, and it
  runs one or more pool strategies **per mandate asset** concurrently off the same treasury.
- **The curator is the AI agent.** Pool creation, rebalancing (dock + re-ship), recycling RWA
  inventory bought at a discount into the `RedemptionQueue` (auto-claiming at settlement via the
  queue's operator model), and fulfilling LP exit epochs are all agent transactions — each logged
  with its subgraph evidence for the Graph track.
- **totalAssets** = idle USDC + shipped Aqua balances (`rawBalances`) + the multi-RWA inventory
  and queue positions valued at `NavOracle` (staleness-bounded; deposits revert on stale NAV).
- Both maker classes coexist on one rail: pro makers ship their own wallets, tier vaults ship
  pooled deposits — the pools are the same order templates either way.

## 6. Router + Uniswap lane

`OutletRouter.redeemInstant(asset, amount, minOut)` quotes Pools 1–3, any isolated resting bids,
and the Uniswap v4 RWA/USDC pool, then executes the best (or hands off to the queue's
`requestRedeem` if the user chose patient mode). Because Pool 3 is two-sided, the router also exposes `buy(asset, usdcIn, minOut)` —
entries route through the Market pool or Uniswap, whichever quotes better.
Uniswap serves two jobs: **fallback venue** when Aqua inventory is thin, and **TWAP sanity bound** —
program quotes deviating > `twapBandBps` from the v4 TWAP revert unless the NavOracle is fresher
than the TWAP window. `RWAGateHook` enforces transfer compliance on the v4 pool, making the
secondary lane a first-class integration alongside Aqua/SwapVM and the subgraph.

The v4 leg executes through **`V4Venue`** (solc 0.8.26 unit; the 0.8.30 router talks to it via
the pragma-neutral `IV4Venue`, same pattern as `IRwaTwapSource`): pools are registered per asset
(sorted asset/USDC pair + `RWAGateHook`), quotes come from the official `V4Quoter` (redeploy,
non-view revert-simulation — `quoteInstantAll`/`quoteBuyAll` are therefore non-view, callable via
`eth_call`), and fills run through the venue's own unlock callback (swap → settle input → take
output straight to the user). The initiating user rides along as `hookData`, so the hook's
compliance gate and TWAP observations see the real user. For v4 fills the router's
`InstantExit`/`Purchase` events carry the v4 PoolId in the `orderHash` slot.

## 7. Events → subgraph → agent (data flows one way)

Every state change emits full context — from the official contracts (Aqua, the SwapVM router) and
from ours (`NavExtruction`, queue, vault, router, oracle, hook); the subgraph and UI see only
events. Per `graph-contracts-sync`, any event/ABI change regenerates `subgraph/abis` + the
front's ABI transcriptions in the same commit series. The subgraph package lives in
`rwa-outlet-contracts-back/subgraph` (`npm run sync` pulls ABIs + addresses from this repo).

| Event (emitter) | Subgraph entity | Agent uses it for |
|---|---|---|
| `Trade(strategyHash, poolId, asset, isExit, maker, taker, amountIn, amountOut, rateVsNavBps)` — `NavExtruction` | `Trade` | Spread/volume monitoring, discount clearing depth |
| `Swapped(orderHash, maker, taker, tokenIn, tokenOut, amountIn, amountOut)` — official router | `Fill` (linked to same-tx `Trade`) | Settlement-level fills, AMM flow imbalance |
| `Shipped/Docked/Pushed/Pulled(maker, app, strategyHash, token, amount)` — official Aqua | `Strategy`, `StrategyBalance` | Inventory + utilization per pool |
| `PoolCreated(strategyHash, asset, kind, amounts, params)/PoolDocked` — `CuratorVault` | `Strategy` (kind + decoded params) | Pool configuration, rebalance tracking |
| `RedeemRequest/Submitted/Settled/Withdraw/RolesSet` — `RedemptionQueue` (ERC-7540) | `Queue`, `QueueEpoch`, `QueueRequest`, `QueueClaim` | Backlog aging, settlement triggers, FIFO claim state |
| `Deposit/RedeemRequest/EpochFulfilled/Withdraw/Recycled/QueueClaimed/MandateAssetAdded` — `CuratorVault` | `Vault`, `VaultDeposit`, `VaultEpoch`, `VaultPosition`, `MandateAsset` | LP flows, share-price history, mandate utilization, recycling loop |
| `InstantExit/Purchase/PatientEnqueued/StrategyRegistered/GuardSet` — `OutletRouter` | `RouterSwap`, `RouterListing`, `TwapGuard` | Venue routing stats, listing set |
| `NavUpdated(asset, nav, timestamp)` — `NavOracle` | `Asset.nav`, `NavPoint` | Staleness alerts, rate anchoring |
| `ObservationRecorded(poolId, sqrtPriceX96, rate1e18, cumulativeX128)` — `RWAGateHook` | `V4Pool`, `Observation` | Secondary-market price series, TWAP context |
| `PoolRegistered(asset, poolId, fee, tickSpacing, hooks)` / `V4Swapped(asset, user, recipient, assetForUsdc, amountIn, amountOut)` — `V4Venue` | `V4Pool`, `RouterSwap` (venue = v4) | Maps PoolIds to assets; v4 fill volume vs Aqua fill volume |
| `Transfer` — `ComplianceNFT` (soulbound) | `KycHolder` | The KYC set, onboarding |
| `Transfer` — demo tokens | `TokenBalance` | Wallet/escrow balances (vault idle USDC, queue escrow) |

**Curator agent loop** (Graph track): query subgraph (utilization, discount clearing levels, queue
backlog, NAV staleness) → reason against policy (e.g. "Pool 2 clearing > 250 bps for 6h → raise
`floorRate`, ship more USDC") → act onchain. Every decision is logged with the query, the entities
it was based on, and the resulting transaction hash — that log is the query → reasoning → action
demo evidence The Graph requires.

## 8. Parameters (initial)

| Param | Pool 1 Express | Pool 2 Patient | Pool 3 Market |
|---|---|---|---|
| Pricing | NAV − 5–25 bps fixed | decay 30 → 300 bps over 30 min | xyc curve + 30 bps fee |
| Assets (demo) | `rwaTBILL` (T+7) | `rwaCREDIT` (T+90) | both |
| Per-asset inventory cap | 500k USDC | 150k USDC | maker-set shipped reserves |
| NAV staleness max | 24h | 24h | n/a (optional NAV band) |
| Queue fee | — | 5 bps | — |

Demo assets are real contracts deployed to Base Sepolia with live keeper-updated NAV (no static
fixtures); the 1inch demo runs on a mainnet fork against real tokenized T-bill tokens and the
official Aqua/SwapVM deployments.

## 9. Invariants & risks

- `quote() == swap()` for identical takerData (tested with swap-vm `AquaOpcodesDebug`), including
  the `NavExtruction` static/state duals — the official Extruction contract requires deterministic,
  identical results in both modes and forbids backward jumps to it.
- Swap-path safety (per-order reentrancy lock, taker-push verification, `pull()`/`push()` only at
  settlement) is enforced inside the official router — not our code, not our audit surface.
- Stale/manipulated NAV is the main oracle risk → hard staleness revert + Uniswap TWAP band.
- Queue solvency is structural (pay only from received settlement); RWA depeg risk sits with makers
  who priced it, never with queue depositors.
- The vault share price depends on `NavOracle` (the multi-RWA treasury is valued at NAV) →
  deposits revert on stale NAV; LP exits are epoch-fulfilled at realized values (no oracle-priced
  instant exits), which closes the classic 4626 stale-price arbitrage.

## 10. Milestones

1. **M1** — Express pool end-to-end: `NavOracle` + `NavExtruction` (fixed-spread mode) +
   `ComplianceNFT`, fork test swapping a real RWA token through the **deployed** official
   Aqua + `AquaSwapVMRouter` (minimum 1inch qualification, runnable `script/Demo.s.sol`).
2. **M2** — Patient pool (decay mode) + Market pool (xyc AMM + NAV band) + isolated resting bids +
   `RedemptionQueue` (ERC-7540/7575).
3. **M3** — `CuratorVault` (mandate + agent-as-curator) + `OutletRouter` + Uniswap v4 pool with
   `RWAGateHook` (TWAP band + fallback); Base Sepolia deploy (`deployments/<chain>.json`).
4. **M4** — Subgraph + curator agent with decision log.
5. **M5** — Front, demo video (fork swap → agent loop → hook-gated v4 trade), README address table.

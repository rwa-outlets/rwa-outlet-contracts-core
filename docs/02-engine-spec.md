# RWA Outlets — Engine spec (page 2 of 2)

Contract-level spec for the engine described in `01-architecture.md`. Stack: Foundry, Solidity
^0.8.24, official 1inch contracts via `forge install 1inch/aqua 1inch/swap-vm` (mainnet: Aqua
`0x499943e74fb0ce105688beee8ef2abec5d936d31`, SwapVM `0x8fdd04dbf6111437b44bbca99c28882434e0958f`
— used directly in fork tests/demo; redeploying official code to Base Sepolia is allowed, never
reimplementing it).

## 1. Contract map

| Contract | Inherits | Role |
|---|---|---|
| `OutletApp` | `AquaApp` | The Aqua app. Holds pool strategies, verifies taker payment (`_safeCheckAquaPush()` + `nonReentrant`), emits all engine events |
| `OutletVM` | `SwapVM` + `OutletOpcodes` | Official SwapVM extended with our instruction set via `_instructions()` override |
| `OutletOpcodes` | — | Custom instructions: `_navAnchorRate` (quote from NavOracle, revert if stale) and `_complianceGate` (allowlist check for gated RWAs) |
| `RedemptionQueue` | ERC-721 | Escrows RWA tokens, mints claim NFTs, pays NAV on issuer settlement |
| `OutletRouter` | — | Single user entry point: best-of quoting across Pool 1 / Pool 2 / Uniswap, and queue deposits |
| `NavOracle` | — | Per-asset NAV pushed by issuer keeper (demo: agent-updated), with staleness bounds |
| `ComplianceRegistry` | — | KYC'd maker allowlist (mirrors Liquid Lane's verified market makers); per-asset taker gating |
| `RWAGateHook` | v4 `BaseHook` | (Stretch) Uniswap v4 hook: transfer compliance + TWAP exposure for the secondary lane |

## 2. Aqua integration (shared capital base)

- Maker lifecycle: one USDC approval to Aqua → `aqua.ship(app, strategy, tokens, amounts)` per pool
  they want to back → `dock()` to exit. Strategy bytes encode `(pool id, asset, params)`, so
  `strategyHash` identifies **pool × asset**. Balances live at
  `balances[maker][app][strategyHash][token]`.
- Orders are built with `MakerTraitsLib.build(...)` carrying the pool's program bytes and
  `useAquaInsteadOfSignature: true` — shipped liquidity replaces EIP-712 signatures, and the same
  wallet balance backs Pool 1 and Pool 2 concurrently.
- `pull()`/`push()` are swap-time settlement **only** (never liquidity management). Taker payment is
  verified with `_safeCheckAquaPush()` behind a reentrancy guard.
- Taker side always calls `quote()` via `asView()` with the *same* takerData later passed to
  `swap()`, plus threshold and deadline.

## 3. SwapVM programs (instruction order is security-critical)

Composed with `ProgramBuilder`; order follows balances → fees → swap → invalidators.

**Pool 1 — Express** (Aqua manages balances, so no balance instruction):

```text
_flatFeeAmountInXD(protocolFee)          // fee taken before pricing
_navAnchorRate(asset, spreadBps)         // custom opcode: rate = NAV × (1 − spread), stale-NAV revert
_limitSwap1D(rate)                       // fill at the anchored rate
_requireMinRate1D(minRate)               // taker slippage floor
_invalidateTokenOut1D()                  // partial fills, capped by shipped inventory
```

**Pool 2 — Patient** (Dutch-decay auction replaces RFQ bidding):

```text
_flatFeeAmountInXD(protocolFee)
_complianceGate(asset)                   // custom opcode: gated RWAs check taker/maker allowlist
_decayXD(startRate → floorRate, T)       // discount decays from tight to floor until filled
_requireMinRate1D(floorRate)             // hard floor = max discount a maker will fund
_invalidateBit1D()                       // one-shot fill for full-position redemption orders
```

Routing uses the official `AquaSwapVMRouter` for shipped-liquidity execution; `OutletVM` is only a
superset (official opcodes + ours), satisfying the "official contracts" rule while hitting the
"custom instructions" scoring bonus.

## 4. RedemptionQueue (delayed lane)

States: `Pending → SubmittedToIssuer → Settled → Claimed`.

- `enqueue(asset, amount)` escrows the RWA token, mints claim NFT with `(asset, amount, navAtEnqueue)`.
- Curator agent batches `submitToIssuer(assetBatch)` per issuer window; issuer settlement delivers
  USDC at `navAtSettle`.
- `claim(id)` pays `amount × navAtSettle − queueFee`. Payouts come only from received settlement
  cash, so the queue cannot be insolvent by construction.
- Spread waterfall on maker-recycled inventory: maker keeps the NAV−discount capture minus
  `curatorFeeBps` (agent treasury) and `protocolFeeBps`.

## 5. Router + Uniswap lane

`OutletRouter.redeemInstant(asset, amount, minOut)` quotes Pool 1, Pool 2, and the Uniswap v4
RWA/USDC pool, executes the best (or reverts to `enqueue` if the user chose patient mode).
Uniswap serves two jobs: **fallback venue** when Aqua inventory is thin, and **TWAP sanity bound** —
program quotes deviating > `twapBandBps` from the v4 TWAP revert unless the NavOracle is fresher
than the TWAP window. `RWAGateHook` enforces transfer compliance on the v4 pool (stretch; a plain
v3-style pool works as fallback-only).

## 6. Events → subgraph → agent (data flows one way)

Every state change emits full context (tokens, amounts, maker/taker, strategyHash) — the subgraph
and UI see only events. Per `graph-contracts-sync`, any event/ABI change regenerates
`subgraph/abis` + `front/src/lib/abi` in the same commit series.

| Event | Subgraph entity | Agent uses it for |
|---|---|---|
| `InstantRedemption(pool, asset, maker, taker, amountIn, usdcOut, discountBps)` | `Redemption` | Spread/volume monitoring, discount depth |
| `LiquidityShipped/Docked(maker, strategyHash, token, amount)` | `MakerPosition` | Inventory + utilization per pool |
| `Enqueued/Submitted/Settled/Claimed(id, asset, amount, nav)` | `QueueTicket` | Backlog aging, settlement triggers |
| `NavUpdated(asset, nav, timestamp)` | `NavPoint` | Staleness alerts, rate anchoring |

**Curator agent loop** (Graph track): query subgraph (utilization, discount clearing levels, queue
backlog, NAV staleness) → reason against policy (e.g. "Pool 2 clearing > 250 bps for 6h → raise
`floorRate`, ship more USDC") → act onchain. **Hedera track**: the agent pays keeper/settlement
bounties on Hedera testnet via Agent Kit v4 (autonomous mode) and logs every decision + tx to an
HCS topic — the audit trail doubles as demo evidence (hashscan links).

## 7. Parameters (initial)

| Param | Pool 1 Express | Pool 2 Patient |
|---|---|---|
| Spread / discount | 5–25 bps fixed | decay 30 → 300 bps over 30 min |
| Assets (demo) | `rwaTBILL` (T+7) | `rwaCREDIT` (T+90) |
| Per-asset inventory cap | 500k USDC | 150k USDC |
| NAV staleness max | 24h | 24h |
| Queue fee | — | 5 bps |

Demo assets are real contracts deployed to Base Sepolia with live keeper-updated NAV (no static
fixtures); the 1inch demo runs on a mainnet fork against real tokenized T-bill tokens and the
official Aqua/SwapVM deployments.

## 8. Invariants & risks

- `quote() == swap()` for identical takerData (tested with swap-vm `OpcodesDebug` + `CoreInvariants`:
  quote/swap consistency, partial fills, invalidation).
- No `pull()/push()` outside swap execution; checks-effects-interactions everywhere.
- Stale/manipulated NAV is the main oracle risk → hard staleness revert + Uniswap TWAP band.
- Queue solvency is structural (pay only from received settlement); RWA depeg risk sits with makers
  who priced it, never with queue depositors.

## 9. Milestones

1. **M1** — `OutletApp` + Express program, fork test swapping a real RWA token through official
   Aqua/SwapVM (minimum 1inch qualification, runnable `script/Demo.s.sol`).
2. **M2** — Patient pool (decay program) + custom opcodes (`OutletVM`) + `RedemptionQueue`.
3. **M3** — `OutletRouter` + Uniswap fallback/TWAP; Base Sepolia deploy (`deployments/<chain>.json`).
4. **M4** — Subgraph + curator agent + Hedera payments/HCS.
5. **M5** — Front, demo video (fork swap → agent loop → Hedera payment), README address table.
